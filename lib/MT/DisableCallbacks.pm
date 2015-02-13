package MT::DisableCallbacks {

    use MT::ConvertDB::ToolSet;
    use vars qw( $l4p );

    my %DisabledCallbacks;
    my %CallbacksEnabled;
    my @Callbacks;
    my ( $run_cb, $add_cb );

    sub import {
        my ( $class, %args ) = @_;

        $DisabledCallbacks{$_} = delete $args{$_} || []
            foreach qw( internal plugins );

        no warnings qw( once redefine );
        require MT;
        $add_cb        = MT->can('add_callback');
        *MT::add_callback = $class->can('mt_add_callback');

        $run_cb        = MT->can('run_callback');
        *MT::run_callback = $class->can('mt_run_callback');

        return;
    }

    sub mt_add_callback {
        my $class = shift;
        my ( $meth, $priority, $plugin, $code ) = @_;
        ###l4p $l4p ||= get_logger();

        # Call the original method which will add the callback
        # but it also does some extra work we want to piggyback on
        my $cb     = $class->$add_cb(@_) or return;
        my $id     = try { $plugin->id } || $plugin || '';

        my $remove = $cb->{internal}
            ? ( grep { $meth eq $_ } @{ $DisabledCallbacks{internal} } )
            : ( grep { $id   eq $_ } @{ $DisabledCallbacks{plugins}  } );

        if ( $remove ) { MT->remove_callback( $cb ); return }
        ###l4p $l4p->debug(
        ###l4p    sprintf "INIT CB: %-5s %-30s %-40s %s\n", $cb->{internal},
        ###l4p         $id, $cb->name, $code ) if $code;
        return $cb;
    }

    sub mt_run_callback {
        my ( $class, $cb, @args ) = @_;
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->debug(
        ###l4p     sprintf "RUN CB: %-5s %-30s %-40s %s\n", $cb->{internal},
        ###l4p         ($cb->plugin && $cb->plugin->id ? $cb->plugin->id : ''),
        ###l4p         $cb->name, $cb->{code}
        ###l4p );
        $class->$run_cb( $cb, @args );
    }
}

1;
