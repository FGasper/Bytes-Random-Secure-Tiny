## no critic (ProhibitMultiplePackages,RequireFilenameMatchesPackage)

# Bytes::Random::Secure::Tiny: A single source file implementation of
# Bytes::Random::Secure, and its dependencies.

# Crypt::Random::Seed::Embedded, taken with consent from    #
# Crypt::Random::Seed, by Dana Jacobson.                    #

package Crypt::Random::Seed::Embedded;
use strict;
use warnings;
use Fcntl;
use Carp qw/carp croak/;

## no critic (constant)

our $VERSION = '1.002';
use constant UINT32_SIZE => 4;

sub new {
    my ($class, %params) = @_;
    $params{lc $_} = delete $params{$_} for keys %params;
    $params{nonblocking}
        = defined $params{nonblocking} ? $params{nonblocking} : 1;
    my $self = {};
    my @methodlist
        = ( \&_try_win32, \&_try_egd, \&_try_dev_random, \&_try_dev_urandom );

    foreach my $m (@methodlist) {
        my ($name, $rsub, $isblocking, $isstrong) = $m->();
        next unless defined $name;
        next if $isblocking && $params{nonblocking};
        @{$self}{qw( Name    SourceSub  Blocking      Strong    )}
                 = ( $name,  $rsub,     $isblocking,  $isstrong );
        last;
    }
    return defined $self->{SourceSub} ? bless $self, $class : ();
}

sub random_values {
    my ($self, $nvalues) = @_;
    return unless defined $nvalues && int($nvalues) > 0;
    my $rsub = $self->{SourceSub};
    return unpack( 'L*', $rsub->(UINT32_SIZE * int($nvalues)) );
}

sub _try_dev_urandom {
    return unless -r "/dev/urandom";
    return ('/dev/urandom', sub { __read_file('/dev/urandom', @_); }, 0, 0);
}

sub _try_dev_random {
    return unless -r "/dev/random";
    my $blocking = $^O eq 'freebsd' ? 0 : 1;
    return ('/dev/random', sub {__read_file('/dev/random', @_)}, $blocking, 1);
}

sub __read_file {
    my ($file, $nbytes) = @_;
    return unless defined $nbytes && $nbytes > 0;
    sysopen(my $fh, $file, O_RDONLY);
    binmode $fh;
    my($s, $buffer, $nread) = ('', '', 0);
    while ($nread < $nbytes) {
        my $thisread = sysread $fh, $buffer, $nbytes-$nread;
        croak "Error reading $file: $!\n"
            unless defined $thisread && $thisread > 0;
        $s .= $buffer;
        $nread += length($buffer);
    }
    croak "Internal file read error: wanted $nbytes, read $nread"
        unless $nbytes == length($s);  # assert
    return $s;
}

sub _try_win32 {
    return unless $^O eq 'MSWin32';
    eval { require Win32; require Win32::API; require Win32::API::Type; 1; }
        or return;

    use constant CRYPT_SILENT      => 0x40;       # Never display a UI.
    use constant PROV_RSA_FULL     => 1;          # Which service provider.
    use constant VERIFY_CONTEXT    => 0xF0000000; # Don't need existing keepairs
    use constant W2K_MAJOR_VERSION => 5;          # Windows 2000
    use constant W2K_MINOR_VERSION => 0;

    my ($major, $minor) = (Win32::GetOSVersion())[1, 2];
    return if $major < W2K_MAJOR_VERSION;

    if ($major == W2K_MAJOR_VERSION && $minor == W2K_MINOR_VERSION) {
        # We are Windows 2000.  Use the older CryptGenRandom interface.
        my $crypt_acquire_context_a =
            Win32::API->new('advapi32', 'CryptAcquireContextA', 'PPPNN','I');
        return unless defined $crypt_acquire_context_a;
        my $context = chr(0) x Win32::API::Type->sizeof('PULONG');
        my $result = $crypt_acquire_context_a->Call(
             $context, 0, 0, PROV_RSA_FULL, CRYPT_SILENT | VERIFY_CONTEXT );
        return unless $result;
        my $pack_type = Win32::API::Type::packing('PULONG');
        $context = unpack $pack_type, $context;
        my $crypt_gen_random =
            Win32::API->new( 'advapi32', 'CryptGenRandom', 'NNP', 'I' );
        return unless defined $crypt_gen_random;
        return ('CryptGenRandom',
            sub {
                my $nbytes = shift;
                my $buffer = chr(0) x $nbytes;
                my $result = $crypt_gen_random->Call($context, $nbytes, $buffer);
                croak "CryptGenRandom failed: $^E" unless $result;
                return $buffer;
            }, 0, 1);  # Assume non-blocking and strong
    } else {
        my $rtlgenrand = Win32::API->new( 'advapi32', <<'_RTLGENRANDOM_PROTO_');
INT SystemFunction036(
  PVOID RandomBuffer,
  ULONG RandomBufferLength
)
_RTLGENRANDOM_PROTO_
        return unless defined $rtlgenrand;
        return ('RtlGenRand',
            sub {
                my $nbytes = shift;
                my $buffer = chr(0) x $nbytes;
                my $result = $rtlgenrand->Call($buffer, $nbytes);
                croak "RtlGenRand failed: $^E" unless $result;
                return $buffer;
            }, 0, 1);  # Assume non-blocking and strong
    }
    return;
}

sub _try_egd {
    my @devices
        = qw(/var/run/egd-pool /dev/egd-pool /etc/egd-pool /etc/entropy);
    foreach my $device (@devices) {
        next unless -r $device && -S $device;
        eval { require IO::Socket; 1; } or return;
        my $socket = IO::Socket::UNIX->new(Peer => $device, Timeout => 1);
        next unless $socket;
        $socket->syswrite( pack("C", 0x00), 1) or next;
        die if $socket->error;
        my($entropy_string, $nread);
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm 1;
            $nread = $socket->sysread($entropy_string, 4);
            alarm 0;
        };
        if ($@) {
            die unless $@ eq "alarm\n";
            next;
        }
        next unless defined $nread && $nread == 4;
        my $entropy_avail = unpack("N", $entropy_string);
        return ('EGD', sub { __read_egd($device, @_); }, 1, 1);
    }
    return;
}

sub __read_egd {
    my ($device, $nbytes) = @_;
    return unless defined $device;
    return unless defined $nbytes && int($nbytes) > 0;
    croak "$device doesn't exist!" unless -r $device && -S $device;
    my $socket = IO::Socket::UNIX->new(Peer => $device);
    croak "Can't talk to EGD on $device. $!" unless $socket;
    my($s, $buffer, $toread) = ('', '', $nbytes);
    while ($toread > 0) {
        my $this_request = ($toread > 255) ? 255 : $toread;
        $socket->syswrite( pack("CC", 0x02, $this_request), 2);
        my $this_grant = $socket->sysread($buffer, $this_request);
        croak "Error reading EDG data from $device: $!\n"
            unless defined $this_grant && $this_grant == $this_request;
        $s .= $buffer;
        $toread -= length($buffer);
    }
    croak "Internal EGD read error: wanted $nbytes, read ", length($s), ""
        unless $nbytes == length($s);  # assert
    return $s;
}

1;

# Math::Random::ISAAC::PP::Embedded: Taken without notice from #
# Math::Random::ISAAC and Math::Random::ISAAC::PP.             #

## no critic (constant,unpack)

package Math::Random::ISAAC::PP::Embedded;

use strict;
use warnings;
use Carp ();

our $VERSION = '1.002';
use constant {
    randrsl => 0, randcnt => 1, randmem => 2,
    randa   => 3, randb   => 4, randc   => 5,
};

sub new {
    my ($class, @seed) = @_;
    my $seedsize = scalar(@seed);
    my @mm;

    $#mm = $#seed = 255;                # predeclare arrays with 256 slots
    $seed[$_] = 0 for $seedsize .. 255; # Zero-fill unused seed space.

    my $self = [ \@seed, 0, \@mm, 0, 0, 0 ];

    bless $self, $class;
    $self->_randinit;
    return $self;
}

sub irand {
    my $self = shift;
    if (!$self->[randcnt]--) {
        $self->_isaac;
        $self->[randcnt] = 255;
    }
    return sprintf('%u', $self->[randrsl][$self->[randcnt]]);
}

## no critic (RequireNumberSeparators,ProhibitCStyleForLoops)

sub _isaac {
    my $self = shift;
    use integer;

    my $mm = $self->[randmem];
    my $r  = $self->[randrsl];
    my $aa = $self->[randa];
    my $bb = ($self->[randb] + (++$self->[randc])) & 0xffffffff;
    my ($x, $y); # temporary storage

    for (my $i = 0; $i < 256; $i += 4) {
        $x = $mm->[$i  ];
        $aa = (($aa ^ ($aa << 13)) + $mm->[($i   + 128) & 0xff]);
        $aa &= 0xffffffff; # Mask out high bits for 64-bit systems
        $mm->[$i  ] = $y = ($mm->[($x >> 2) & 0xff] + $aa + $bb) & 0xffffffff;
        $r->[$i  ] = $bb = ($mm->[($y >> 10) & 0xff] + $x) & 0xffffffff;

        $x = $mm->[$i+1];
        $aa = (($aa ^ (0x03ffffff & ($aa >> 6))) + $mm->[($i+1+128) & 0xff]);
        $aa &= 0xffffffff;
        $mm->[$i+1] = $y = ($mm->[($x >> 2) & 0xff] + $aa + $bb) & 0xffffffff;
        $r->[$i+1] = $bb = ($mm->[($y >> 10) & 0xff] + $x) & 0xffffffff;

        $x = $mm->[$i+2];
        $aa = (($aa ^ ($aa << 2)) + $mm->[($i+2 + 128) & 0xff]);
        $aa &= 0xffffffff;
        $mm->[$i+2] = $y = ($mm->[($x >> 2) & 0xff] + $aa + $bb) & 0xffffffff;
        $r->[$i+2] = $bb = ($mm->[($y >> 10) & 0xff] + $x) & 0xffffffff;

        $x = $mm->[$i+3];
        $aa = (($aa ^ (0x0000ffff & ($aa >> 16))) + $mm->[($i+3 + 128) & 0xff]);
        $aa &= 0xffffffff;
        $mm->[$i+3] = $y = ($mm->[($x >> 2) & 0xff] + $aa + $bb) & 0xffffffff;
        $r->[$i+3] = $bb = ($mm->[($y >> 10) & 0xff] + $x) & 0xffffffff;
    }

    @{$self}[randb, randa] = ($bb,$aa);
    return;
}

sub _randinit {
    my $self = shift;
    use integer;

    my ($c, $d, $e, $f, $g, $h, $j, $k) = (0x9e3779b9)x8; # The golden ratio.
    my $mm = $self->[randmem];
    my $r  = $self->[randrsl];

    for (1..4) {
        $c ^= $d << 11;                     $f += $c;       $d += $e;
        $d ^= 0x3fffffff & ($e >> 2);       $g += $d;       $e += $f;
        $e ^= $f << 8;                      $h += $e;       $f += $g;
        $f ^= 0x0000ffff & ($g >> 16);      $j += $f;       $g += $h;
        $g ^= $h << 10;                     $k += $g;       $h += $j;
        $h ^= 0x0fffffff & ($j >> 4);       $c += $h;       $j += $k;
        $j ^= $k << 8;                      $d += $j;       $k += $c;
        $k ^= 0x007fffff & ($c >> 9);       $e += $k;       $c += $d;
    }

    for (my $i = 0; $i < 256; $i += 8) {
        $c += $r->[$i  ];   $d += $r->[$i+1];
        $e += $r->[$i+2];   $f += $r->[$i+3];
        $g += $r->[$i+4];   $h += $r->[$i+5];
        $j += $r->[$i+6];   $k += $r->[$i+7];

        $c ^= $d << 11;                     $f += $c;       $d += $e;
        $d ^= 0x3fffffff & ($e >> 2);       $g += $d;       $e += $f;
        $e ^= $f << 8;                      $h += $e;       $f += $g;
        $f ^= 0x0000ffff & ($g >> 16);      $j += $f;       $g += $h;
        $g ^= $h << 10;                     $k += $g;       $h += $j;
        $h ^= 0x0fffffff & ($j >> 4);       $c += $h;       $j += $k;
        $j ^= $k << 8;                      $d += $j;       $k += $c;
        $k ^= 0x007fffff & ($c >> 9);       $e += $k;       $c += $d;

        $mm->[$i  ] = $c;   $mm->[$i+1] = $d;
        $mm->[$i+2] = $e;   $mm->[$i+3] = $f;
        $mm->[$i+4] = $g;   $mm->[$i+5] = $h;
        $mm->[$i+6] = $j;   $mm->[$i+7] = $k;
    }

    for (my $i = 0; $i < 256; $i += 8) {
        $c += $mm->[$i  ];  $d += $mm->[$i+1];
        $e += $mm->[$i+2];  $f += $mm->[$i+3];
        $g += $mm->[$i+4];  $h += $mm->[$i+5];
        $j += $mm->[$i+6];  $k += $mm->[$i+7];

        $c ^= $d << 11;                     $f += $c;       $d += $e;
        $d ^= 0x3fffffff & ($e >> 2);       $g += $d;       $e += $f;
        $e ^= $f << 8;                      $h += $e;       $f += $g;
        $f ^= 0x0000ffff & ($g >> 16);      $j += $f;       $g += $h;
        $g ^= $h << 10;                     $k += $g;       $h += $j;
        $h ^= 0x0fffffff & ($j >> 4);       $c += $h;       $j += $k;
        $j ^= $k << 8;                      $d += $j;       $k += $c;
        $k ^= 0x007fffff & ($c >> 9);       $e += $k;       $c += $d;

        $mm->[$i  ] = $c;   $mm->[$i+1] = $d;
        $mm->[$i+2] = $e;   $mm->[$i+3] = $f;
        $mm->[$i+4] = $g;   $mm->[$i+5] = $h;
        $mm->[$i+6] = $j;   $mm->[$i+7] = $k;
    }

    $self->_isaac;
    $self->[randcnt] = 256;
    return;
}

1;

package Math::Random::ISAAC::Embedded;

use strict;
use warnings;
use Carp ();

our $VERSION = '1.002';
use constant _backend => 0;

my %CSPRNG = (
    XS  => 'Math::Random::ISAAC::XS',
    PP  => 'Math::Random::ISAAC::PP',
    EM  => 'Math::Random::ISAAC::PP::Embedded',
);

sub new {
    my ($class, @seed) = @_;
    our $EMBEDDED_CSPRNG =
        defined $EMBEDDED_CSPRNG             ? $EMBEDDED_CSPRNG             :
        defined $ENV{'BRST_EMBEDDED_CSPRNG'} ? $ENV{'BRST_EMBEDDED_CSPRNG'} : 0;
    my $DRIVER =
        $EMBEDDED_CSPRNG                          ? $CSPRNG{'EM'} :
        eval {require Math::Random::ISAAC::XS; 1} ? $CSPRNG{'XS'} :
        eval {require Math::Random::ISAAC::PP; 1} ? $CSPRNG{'PP'} :
                                                    $CSPRNG{'EM'};
    return bless [$DRIVER->new(@seed)], $class;
}

sub irand {shift->[_backend]->irand}

1;

package Bytes::Random::Secure::Tiny;

use strict;
use warnings;
use 5.006000;
use Carp qw(carp croak);
use Hash::Util;

our $VERSION = '1.002';

# See Math::Random::ISAAC https://rt.cpan.org/Public/Bug/Display.html?id=64324
use constant SEED_SIZE => 256; # bits; eight 32-bit words.

sub new {
    my($self, $class, %args) = ({}, @_);
    $args{lc $_} = delete $args{$_} for keys %args; # Convert args to lc names
    my $bits = SEED_SIZE; # Default: eight 32bit words.
    $bits = delete $args{bits} if exists $args{bits};
    croak "Number of bits must be 64 <= n <= 8192, and a multipe in 2^n: $bits"
        if $bits < 64 || $bits > 8192 || !_ispowerof2($bits);
    return Hash::Util::lock_hashref bless {
        bits => $bits,
        _rng => Math::Random::ISAAC::Embedded->new(do{
            my $source = Crypt::Random::Seed::Embedded->new(%args)
                or croak 'Could not get a seed source.';
            $source->random_values($bits/32);
        }),
    }, $class;
}

sub _ispowerof2 {my $n = shift; return ($n >= 0) && (($n & ($n-1)) ==0 )}
sub irand {shift->{'_rng'}->irand}
sub bytes_hex {unpack 'H*', shift->bytes(shift)} # lc Hex digits only, no '0x'

sub bytes {
      my($self, $bytes) = @_;
    $bytes  = defined $bytes ? int abs $bytes : 0; # Default 0, coerce to UINT.
    my $str = q{};
    while ($bytes >= 4) {                  # Utilize irand()'s 32 bits.
        $str .= pack("L", $self->irand);
        $bytes -= 4;
    }
    if ($bytes > 0) { # Handle 16b and 8b respectively.
        $str .= pack("S", ($self->irand >> 8) & 0xFFFF) if $bytes >= 2;
        $str .= pack("C", $self->irand & 0xFF) if $bytes % 2;
    }
    return $str;
}

sub string_from {
    my($self, $bag, $bytes) = @_;
    $bag           = defined $bag ? $bag : q{};
    $bytes         = defined $bytes ? int abs $bytes : 0;
    my $range      = length $bag;
    croak 'Bag size must be at least one character.' unless $range;
    my $rand_bytes = q{}; # We need an empty, defined string.
    $rand_bytes .= substr $bag, $_, 1 for $self->_ranged_randoms($range, $bytes);
    return $rand_bytes;
}

sub _ranged_randoms {
    my ($self, $range, $count) = @_;
    $_ = defined $_ ? $_ : 0 for $count, $range;
    croak "$range exceeds irand max limit of 2^^32." if $range > 2**32;

    # Find nearest factor of 2**32 >= $range.
    my $divisor = do {
        my ($n, $d) = (0,0);
        while ($n <= 32 && $d < $range) {$d = 2 ** $n++}
        $d;
    };
    my @randoms;
    $#randoms = $count-1; @randoms = (); # Microoptimize: Preextend & purge.

    for my $n (1 .. $count) { # re-roll if r-num is out of bag range (modbias)
        my $rand = $self->irand % $divisor;
        $rand    = $self->irand % $divisor while $rand >= $range;
        push @randoms, $rand;
    }
    return @randoms;
}

1;

=pod

=head1 NAME

Bytes::Random::Secure::Tiny - A tiny Perl extension to generate
cryptographically-secure random bytes.

=head1 SYNOPSIS

    use Bytes::Random::Secure::Tiny;

    my $rng = Bytes::Random::Secure->new; # Seed with 256 bits.

    my $bytes  = $rng->bytes(32);        # A string of 32 random bytes.
    my $long   = $rng->irand;            # 32-bit random unsigned integer.
    my $hex    = $rng->hex_digits(10);   # Ten hex digits (lower-case).
    my $string = $rng->string_from('abc', 10); Random string from a, b, & c.


=head1 DESCRIPTION

L<Bytes::Random::Secure::Tiny> provides random bytes from a cryptographically
secure random number generator (ISAAC), seeded from strong entropy sources on
a wide variety of platforms. It does so without external dependencies (except
on Windows), and has a minimal but useful user interface patterned after the
module L<Bytes::Random::Secure>.

L<Bytes::Random::Secure> has a handful of dependencies. And its UI may be
bigger than a typical user needs. L<Bytes::Random::Secure::Tiny> is designed
to provide what 90% of Bytes::Random::Secure's users need, but with a simpler
user interface, and in a single module with no dependencies beyond core Perl.

In most cases this module may be used as a light-weight drop-in replacement
for L<Bytes::Random::Secure>.

=head1 RATIONALE

This module aims to provide a generalized tool for generating cryptographically
secure randomness in a way that can fit into many applications while providing
a zero dependency chain, and a user interface that is both minimal and simple.
Common use-cases may include:

=over 4

=item * Creating temporary passphrases using the C<string_from> method.

=item * Generating per-account random salt to be hashed along with passphrases 
to prevent rainbow table attacks.

=item * Generating a secret that can be hashed along with a cookie's session
content to prevent cookie forgeries.

=item * Building raw cryptographic-quality pseudo-random data sets for testing
or sampling.

=item * Feeding secure key-gen utilities.

=back

L<Bytes::Random::Secure::Tiny> employs several well-designed algorithms
adapted from established CPAN tools to generate a strong random seed, and then
to instantiate a high quality cryptographically secure pseudo-random number
generator based on the seed. It has taken significant research to come up with
a strong and sensible choice of established and published algorithms. The
interface is designed with minimalism and simplicity in mind.

In particular, the CSPRNG is based on the same algorithm used by 
L<Math::Random::ISAAC>, and the seeding is based on algorithms from 
L<Crypt::Random::Seed>.

Furthermore, this module runs its randomness through both statistical tests
and NIST L<FIPS-140|https://en.wikipedia.org/wiki/FIPS_140> tests to verify
integrity.

As a C<::Tiny> module, the additional goals of low (or no) dependencies and a
light-weight code base make this an ideal choice for environments where heavier
dependency chains are problematic.

=head1 EXPORTS

Nothing is exported.

=head1 METHODS

=head2 new

    my $rng = Bytes::Random::Secure::Tiny->new;

Instantiate the pseudo-random number generator object. The seeding of the ISAAC
CSPRING defaults to 256 bits from a non-blocking entropy source. The CSPRNG
object should be instantiated as infrequently as practical; there is no benefit
to re-seeding, with the single cavaet that the CSPRNG object should not be
shared by threads or forked processes.

=head3 Constructor parameters

Parameters described below are optional and case-insensitive.

=over 4

=item bits

    my $rng = Bytes::Random::Secure::Tiny->new(bits => 512);

Number of bits to use in seeding. Must be a value between 64 and 8192
inclusive, and must satisfy C<bits=2**n>.  The default value is 256.

=item nonblocking

    my $nb_rng = Bytes::Random::Secure::Tiny->new(nonblocking=>1);
    my $bl_rng = Bytes::Random::Secure::Tiny->new(nonblocking=>0);

If set to a false value, a blocking entropy source may be used in seeding. This
is generally not necessary, as the non-blocking sources used are considered by 
most to be strong enough for cryptographic purposes. But for extremely
sensitive purposes, or in environments where the blocking entropy sources are
supported by hardware entropy generators, this option may be useful.

Instantiating with a blocking source can exhaust system entropy (this has been
seen in testing), and in such cases C<new> will block until sufficient entropy
is generated.

The default is to use a non-blocking source, and you should probably accept
that default.

=back

=head2 bytes

    my $random_bytes = $rng->bytes($n);

Returns a string of C<$n> random bytes. C<$n> must be a positive integer.

=head2 string_from

    my $random_string = $rng->string_from('abcdefg', 10);

Returns a string of random octets selected from the "Bag" string (in this case
ten octets from 'abcdefg').

=head2 bytes_hex

    my $random_hex = $rng->bytes_hex(12);

Returns a string of hex digits. Each byte is represented by two lower-cased hex
digits. Therefore, C<<$rng->bytes_hex(1)>> will return a string of length 2,
such as C<7F>. There is no C<0x> prepended to the hex digits.

=head2 irand

    my $unsigned_long = $random->irand;

Returns a pseudo-random 32-bit unsigned integer.  The value will satisfy
C<< 0 <= x <= 2**32-1 >>.

=head1 CONFIGURATION

There is nothing to configure.

=head1 DEPENDENCIES

This module requires Perl 5.8 or newer. Unicode support in C<string_from> is
best with Perl 5.8.9 or newer. See the INSTALLATION section in this document
for details.

=head1 OPTIONAL DEPENDENCIES

L<Bytes::Random::Secure::Tiny> uses an embedded version of the ISAAC
algorithm adapted from L<Math::Random::ISAAC> as its CSPRNG, but will
silently upgrade to using L<Math::Random::ISAAC> proper if it is available
on the target system.

C<Bytes::Random::Secure::Tiny> seeds using an embedded adaptation of
L<Crypt::Random::Seed>, but it will silently upgrade to using
L<Crypt::Random::Seed> proper if it is available on the target system.

If performance is a consideration and you are able to install
L<Math::Random::ISAAC::XS>, do so; L<Bytes::Random::Secure::Tiny> will
silently upgrade to using C<Math::Random::ISAAC::XS> instead of the embedded
ISAAC CSPRING. L<Math::Random::ISAAC::XS> implements the same ISAAC CSPRNG
algorithm in C and XS for speed.

=head1 FORK AND THREAD SAFETY

When programming for parallel computation, create a unique
C<Bytes::Random::Secure::Tiny> object within each process or thread.
L<Bytes::Random::Secure::Tiny> uses a CSPRNG, and sharing the same RNG between
threads or processes will share the same seed and the same starting point. By
instantiating the B::R::S::T object after forking or creating threads, a unique
randomness stream will be created per thread or process.

Always share the same RNG object between all non-concurrent consumers within
a process, but never share the same RNG between threads or forked processes.

=head1 ADDITIONAL DISCUSSION

=head2 STRONG RANDOMNESS

It's easy to generate weak pseudo-random bytes. It's also easy to think you're
generating strong pseudo-random bytes when really you're not. And it's hard to
test for pseudo-random cryptographic acceptable quality. There are many high
quality random number generators that are suitable for statistical purposes,
but not necessarily up to the rigors of cryptographic use.

Assuring strong (ie, secure) random bytes in a way that works across a wide
variety of platforms is also challenging. A primary goal for this module is to
provide cryptographically secure pseudo-random bytes while still meeting the
secondary goals of simplicity, minimalism, and no dependencies. If more
fine-grained control over seeding methods is needed, use
L<Bytes::Random::Secure> instead.

=head2 ISAAC

The L<ISAAC algorithm|https://en.wikipedia.org/wiki/ISAAC_(cipher)> is
considered a cryptographically strong pseudo-random number generator. It has
1.0e2466 possible initial states. The best known attack for discovering initial
state would theoretically take a complexity of approximately 4.67e1240, which
is of no practical consequence to ISAAC's security. Cycles are guaranteed to
have a minimum length of 2**40, with an average cycle of 2**8295. Because there
is no practical attack capable of discovering initial state, and because the
average cycle is so long, it's generally unnecessary to re-seed a running
application. The results are uniformly distributed, unbiased, and unpredictable
unless the seed is known.

To confirm the quality of the CSPRNG, this module's test suite implements the
L<FIPS-140-1|http://csrc.nist.gov/publications/fips/fips1401.htm> tests for
strong random number generators. See the comments in C<t/27-fips140-1.t> for
details.

=head2 UNICODE SUPPORT

The C<string_from> method permits the user to pass a "bag" (or source) string
containing Unicode characters. For any modern Perl version, this will work
just as you would hope. But some versions of Perl older than 5.8.9 exhibited
varying degrees of bugginess in their handling of Unicode. If you're depending
on the Unicode features of this module while using Perl versions older than
5.8.9 be sure to test thoroughly, and don't be surprised when the outcome isn't
as expected. ...this is to be expected. Upgrade. This module works at the 
octet level, not grapheme cluster.

=head1 MODULO BIAS

Care is taken so that there is no modulo bias in the randomness returned. This
is exactly I<why> the C<string_from> method is preferable to a home-grown
random string solution. However, the algorithm to eliminate modulo bias can
impact the performance of the C<string_from> method. Any time the length of the
bag string is significantly less than the nearest greater or equal factor of
2**32, performance will degrade. Unfortunately there is no known algorithm that
improves upon this situation. Fortunately, for sanely sized strings, it's a
minor issue. To put it in perspective, even in the case of passing a "bag"
string of length 2**31 (which is huge), the expected time to return random
bytes will only double.

=head1 INSTALLATION

No special requirements.

=head1 AUTHOR

David Oswald C<< <davido [at] cpan (dot) org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-bytes-random-secure at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Bytes-Random-Secure-Tiny>.  I
will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Bytes::Random::Secure

You can also look for information at:

=over 4

=item * Github Repo: L<https://github.com/daoswald/Bytes-Random-Secure-Tiny>

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Bytes-Random-Secure-Tiny>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Bytes-Random-Secure-Tiny>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Bytes-Random-Secure-Tiny>

=item * Search CPAN

L<http://search.cpan.org/dist/Bytes-Random-Secure-Tiny/>

=back

=head1 ACKNOWLEDGEMENTS

Dana Jacobsen ( I<< <dana@acm.org> >> ) for his work that led to
L<Crypt::Random::Seed>, and for ideas and code reviews.

=head1 LICENSE AND COPYRIGHT

Copyright 2015 David Oswald.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

