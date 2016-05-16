package Params::CheckCompiler::Compiler;

use strict;
use warnings;

our $VERSION = '0.01';

use Eval::Closure;
use Params::CheckCompiler::Exception::Required;
use Params::CheckCompiler::Exception::Unknown;
use Params::CheckCompiler::Exception::ValidationFailedForMooseTypeConstraint;
use Scalar::Util qw( blessed );

use Moo;

has params => (
    is       => 'ro',
    required => 1,
);

has allow_unknown => (
    is      => 'ro',
    default => 0,
);

has _source => (
    is      => 'ro',
    default => sub { [] },
);

has _env => (
    is      => 'ro',
    default => sub { {} },
);

sub subref {
    my $self = shift;
    $self->_compile;
    return eval_closure(
        source => 'sub { ' . ( join "\n", @{ $self->_source } ) . ' };',
        environment => $self->_env,
    );
}

sub source {
    my $self = shift;
    $self->_compile;

    return (
        ( join "\n", @{ $self->_source } ),
        $self->_env,
    );
}

sub _compile {
    my $self = shift;

    push @{ $self->_source },
        q<my %args = @_ == 1 && Scalar::Util::reftype( $_[0] ) eq 'HASH' ? %{ $_[0] } : @_;>;

    my $params = $self->params;

    for my $name ( keys %{$params} ) {
        my $spec = $params->{$name};
        $spec = { optional => !$spec } unless ref $spec;

        my $qname  = B::perlstring($name);
        my $access = "\$args{$qname}";

        $self->_add_check_for_required( $access, $name )
            unless $spec->{optional};

        $self->_add_type_check( $access, $name, $spec->{type} )
            if $spec->{type};
    }

    $self->_add_check_for_unknown
        unless $self->allow_unknown;

    return;
}

sub _add_type_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    die "Passed a type that is not an object for $name: $type"
        unless blessed $type;

    push @{ $self->_source }, sprintf( 'if ( exists %s ) {', $access );

    # Type::Tiny API
    if ( $type->can('can_be_inlined') && $type->can('inline_assert') ) {
        $self->_add_type_tiny_check( $access, $name, $type );
    }

    # Specio
    elsif ( $type->can('can_inline_coercion_and_check') ) {
        $self->_add_specio_check( $access, $name, $type );
    }

    # Moose
    elsif ( $type->can('can_be_inlined') ) {
        $self->_add_moose_check( $access, $name, $type );
    }
    push @{ $self->_source }, '}';

    return;
}

sub _add_type_tiny_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    if ( $type->has_coercion ) {
        my $coercion = $type->coercion;
        if ( $coercion->can_be_inlined ) {
            push @{ $self->_source },
                "$access = " . $coercion->inline_coercion($access) . ';';
        }
        else {
            $self->_env->{'%tt_coercions'}{$name}
                = $coercion->compiled_coercion;
            push @{ $self->_source },
                sprintf(
                '%s = $tt_coercions{%s}->( %s );',
                $access, $name, $access,
                );
        }
    }

    if ( $type->can_be_inlined ) {
        push @{ $self->_source },
            $type->inline_assert($access);
    }
    else {
        push @{ $self->_source },
            sprintf( '$types{%s}->assert_valid( %s );', $name, $access );
        $self->_env->{'%types'}{$name} = $type;
    }

    return;
}

sub _add_specio_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    my $qname = B::perlstring($name);

    if ( $type->can_inline_coercion_and_check ) {
        my ( $source, $env ) = $type->inline_coercion_and_check($access);
        push @{ $self->_source }, sprintf( '%s = %s', $access, $source );
        $self->_env->{$_} = $env->{$_} for keys %{$env};
    }
    else {
        my @coercions = $type->coercions;
        $self->_env->{'%specio_coercions'}{$name} = \@coercions;
        for my $i ( 0 .. $#coercions ) {
            my $c = $coercions[$i];
            if ( $c->can_be_inlined ) {
                push @{ $self->_source },
                    sprintf(
                    '%s = %s if %s;',
                    $access,
                    $c->inline_coercion($access),
                    $c->from->inline_check($access)
                    );
            }
            else {
                push @{ $self->_source },
                    sprintf(
                    '%s = $specio_coercions{%s}[%s]->coerce(%s) if $specio_coercions{%s}[%s]->from->value_is_valid(%s);',
                    $access,
                    $qname,
                    $i,
                    $access,
                    $qname,
                    $i,
                    $access
                    );
            }
        }

        push @{ $self->_source },
            sprintf( '$types{%s}->validate_or_die(%s)', $name, $access );
        $self->_env->{'%types'}{$name} = $type;
    }

    return;
}

sub _add_moose_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    if ( $type->has_coercion ) {
        $self->_env->{'%moose_coercions'}{$name} = $type->coercion;
        push @{ $self->_source },
            sprintf(
            '%s = $moose_coercions{%s}->coerce( %s );',
            $access, $name, $access,
            );
    }

    $self->_env->{'%types'}{$name} = $type;

    my $code = <<'EOF';
if ( !%s ) {
    my $type = $types{%s};
    my $msg  = $type->get_message(%s);
    die
        Params::CheckCompiler::Exception::ValidationFailedForMooseTypeConstraint
        ->new(
        message   => $msg,
        parameter => 'The ' . %s . ' parameter',
        value     => %s,
        type      => $type,
        );
}
EOF

    my $check
        = $type->can_be_inlined
        ? $type->_inline_check($access)
        : sprintf( '$types{%s}->check( %s )', $name, $access );

    my $qname = B::perlstring($name);
    push @{ $self->_source }, sprintf(
        $code,
        $check,
        $qname,
        $access,
        $qname,
        $access,
    );

    return;
}

sub _add_check_for_required {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;

    my $qname = B::perlstring($name);
    push @{ $self->_source }, sprintf( <<'EOF', $access, ($qname) x 2 );
exists %s
    or Params::CheckCompiler::Exception::Required->throw(
    message   => %s . ' is a required parameter',
    parameter => %s,
    );
EOF

    return;
}

sub _add_check_for_unknown {
    my $self = shift;

    $self->_env->{'%known'} = { map { $_ => 1 } keys %{ $self->params } };
    push @{ $self->_source }, <<'EOF';
my @unknown = grep { ! $known{$_} } keys %args;
if ( @unknown ) {
    my $u = join ', ', sort @unknown;
    Params::CheckCompiler::Exception::Unknown->throw(
        message    => "found unknown parameters: [$u]",
        parameters => \@unknown,
    );
}
EOF

    return;
}

1;