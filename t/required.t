use strict;
use warnings;

use Test2::Bundle::Extended;

use Params::CheckCompiler qw( compile );
use Types::Standard qw( Int );

{
    my $sub = compile(
        params => {
            foo => 1,
            bar => {
                type     => Int,
                optional => 1,
            },
        },
    );

    is(
        dies { $sub->( foo => 42 ) },
        undef,
        'lives when given foo param but no bar'
    );

    is(
        dies { $sub->( foo => 42, bar => 42 ) },
        undef,
        'lives when given foo and bar params'
    );

    like(
        dies { $sub->( bar => 42 ) },
        qr/foo is a required parameter/,
        'dies when not given foo param'
    );
}

done_testing();
