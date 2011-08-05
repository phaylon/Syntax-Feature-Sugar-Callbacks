use strictures 1;

# ABSTRACT: Add sugar for declarative method callbacks

package Syntax::Feature::Sugar::Callbacks;

use Carp                                qw( croak );
use Params::Classify        0.011       qw( is_ref is_string );
use Devel::Declare          0.006000    ();
use Data::Dump                          qw( pp );
use B::Hooks::EndOfScope    0.09;

use aliased 'Devel::Declare::Context::Simple', 'Context';

use namespace::clean 0.18;

$Carp::Internal{ +__PACKAGE__ }++;


=method install

    $class->install( %arguments )

Called by L<syntax> (or others) to install this extension into a namespace.

=cut

sub install {
    my ($class, %args) = @_;
    my $target  = $args{into};
    my $options = $class->_prepare_options($args{options});
    my @names   = keys %{ $options->{ -callbacks } };
    for my $callback (@names) {
        my $callback_options = $options->{ -callbacks }{ $callback };
        croak qq{Value for $class callback '$callback' needs to be hash ref}
            unless is_ref $callback_options, 'HASH';
        croak qq{Option $_ for callback '$callback' needs to be array ref}
            for grep {
                my $value = $options->{ -callbacks }{ $callback }{ $_ };
                defined($value) and not is_ref($value, 'ARRAY');
            } qw( -before -middle );
        croak qq{Can't setup sugar for non-existant '$callback' in $target}
            unless $target->can($callback);
        Devel::Declare->setup_for(
            $target => { $callback => { const => sub {
                my $ctx = Context->new;
                $ctx->init(@_);
                return $class->_transform(
                    $ctx,
                    $options,
                    $callback_options,
                );
            }}},
        );
    }
    return 1;
}


#
#   private methods
#

sub _transform {
    my ($class, $ctx, $options, $cb_options) = @_;
    $ctx->skip_declarator;
    $ctx->skipspace;
    $class->_inject($ctx, '(');
    my $name = $class->_strip_name_portion($ctx, $cb_options);
    my ($invocants, $parameters) = $class->_strip_signature($ctx, $options);
    my $attrs = $ctx->strip_attrs;
    if (defined $name) {
        $class->_inject($ctx, $name);
        $class->_inject($ctx, ',');
    }
    $class->_inject($ctx, ' sub ');
    $class->_inject($ctx, $attrs)
        if defined($attrs);
    $class->_inject($ctx, sprintf('BEGIN { %s->%s }; my (%s) = @_; (); ',
        $class,
        '_handle_scope_end',
        join(', ',
            @{ $cb_options->{ -before } || [] },
            @$invocants,
            @{ $cb_options->{ -middle } || [] },
            @$parameters,
        ),
    ), 1);
    return 1;
}

sub _handle_scope_end {
    my ($class) = @_;
    on_scope_end {
        my $linestr = Devel::Declare::get_linestr;
        my $offset  = Devel::Declare::get_linestr_offset;
        substr($linestr, $offset, 0) = ');';
        Devel::Declare::set_linestr($linestr);
    };
    return 1;
}

sub _inject {
    my ($class, $ctx, $code, $into_block) = @_;
    $ctx->skipspace;
    my $linestr = $ctx->get_linestr;
    my $reststr = substr $linestr, $ctx->offset;
    my $skip    = 0;
    if ($into_block) {
        croak sprintf q{Expected a block for '%s', not: %s},
                $ctx->declarator,
                $reststr,
            unless $reststr =~ m{ \A \{ }x;
        $skip = 1;
    }
    substr($reststr, $skip, 0)      = $code;
    substr($linestr, $ctx->offset)  = $reststr;
    $ctx->set_linestr($linestr);
    $ctx->inc_offset($skip + length $code);
    return 1;
}

sub _strip_signature {
    my ($class, $ctx, $options) = @_;
    $ctx->skipspace;
    my $invocant_option = $options->{ -invocant };
    my @invocants = length($invocant_option)
        ? ($invocant_option)
        : ();
    my $signature = $ctx->strip_proto;
    return [@invocants], []
        unless defined $signature and length $signature;
    my @parts =
        map { [ split m{ \s* , \s* }x, $_ ] }
        split m{ \s* : \s* }x, $signature;
    return  @parts == 1  ? ([@invocants], @parts)
        :   @parts == 2  ? (@parts)
        :   @parts == 0  ? ([@invocants], [])
        :   croak q{Only expected to find a single ':' in signature};
}

sub _strip_name_portion {
    my ($class, $ctx, $options) = @_;
    my $linestr = $ctx->get_linestr;
    if (my $name = $ctx->strip_name) {
        return pp($name);
    }
    if (
            substr($linestr, $ctx->offset) =~ m{ \A " }x
        and Devel::Declare::toke_scan_str $ctx->offset
    ) {
        my $string = Devel::Declare::get_lex_stuff;
        Devel::Declare::clear_lex_stuff;
        substr($linestr, $ctx->offset, 2 + length $string) = '';
        $ctx->set_linestr($linestr);
        return qq{"$string"};
    }
    else {
        return undef
            if $options->{-allow_anon};
        croak sprintf q{Expected a name after '%s' keyword},
            $ctx->declarator;
    }
}

sub _prepare_options {
    my ($class, $options) = @_;
    $options = {}
        unless defined $options;
    croak qq{Expected options for $class to be a hash ref}
        unless is_ref $options, 'HASH';
    $options->{ -invocant } = '$self'
        unless defined $options->{ -invocant };
    croak qq{Option -invocant for $class has to be filled string}
        unless is_string $options->{ -invocant };
    croak qq{Option -callbacks for $class has to be a hash ref}
        unless is_ref $options->{ -callbacks };
    return $options;
}

1;

__END__

=head1 SYNOPSIS

    use AnythingExportingMethodModifiers;
    use syntax 'sugar/callbacks' => {
        -callbacks => {
            after   => {},
            before  => {},
            around  => { -before => ['$orig'] },
        },
    };

    after  foo ($n) { $self->something($n) }
    before bar ($n) { $self->something($n) }
    around baz ($n) { $self->something($self->$orig($n)) }

=head1 DESCRIPTION

You probably won't use this extension directly. That's why it doesn't even
have an C<import> method. Its main reasoning is the ability to provide
on-the-fly sugar for method declarators, most commonly C<before>, C<after>
and C<around>. This extension will directly dispatch to the original
subroutine, and requires these to be setup before-hand. Currently, all
callbacks will first receive the name of the declared method, followed by
the code reference.

Note that no cleanup of the original handlers will be performed. This is
up to the exporting library or the user.

=head1 SYNTAX

All declarations must currently be in one of the forms

    <keyword> <name> (<signature>) { <body> }
    <keyword> <name> { <body> }

The C<keyword> is the name of the declared callback. The C<name> can either
be an identifier like you'd give to C<sub>, or a double-quoted string if
you want the name to be dynamic:

    after "$name" ($arg) { ... }

The signature, if specified, should be in one of the following forms:

    ($foo)
    ($foo, $bar)
    ($class:)
    ($class: $foo, $bar)

Variables before C<:> will be used as replacement for the invocant.
Parameters specified via C<-before> and C<-middle> will always be included.

The statement will automatically terminate after the block. The return
value will be whatever the original callback returns.

You can supply subroutine attributes right before the block.

=head1 OPTIONS

=head2 -invocant

Defaults to C<$self>, but you might want to change this for very specialized
classes.

=head2 -callbacks

This is the set of callbacks that should be setup. It should be a hash
reference using callback names as keys and hash references of options as
values. Possible per-callback options are C<-before> and C<-middle>. The
C<-before> option is an array reference of parameters that come before the
invocant. C<-middle> declares parameters going after the invocants, but
before the parameters specified in the signature.

=head1 SEE ALSO

=over

=item * L<syntax>

=item * L<Devel::Declare>

=back

=cut
