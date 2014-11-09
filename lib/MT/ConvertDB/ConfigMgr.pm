package MT::ConvertDB::ConfigMgr;

# use MT::ConvertDB::Base 'Class';
use MT::ConvertDB::ToolSet;
use MT::ConvertDB::DBConfig;
use vars qw( $l4p );

has read_only => (
    is      => 'ro',
    required => 1,
    trigger  => 1,
);

has old_config => (
    is        => 'lazy',
    init_arg  => 'old',
    coerce    => quote_sub(q( MT::ConvertDB::DBConfig->new( $_[0] ); )),
    predicate => 1,
    default   => './mt-config.cgi',
);

has new_config => (
    is        => 'ro',
    lazy      => 1,
    init_arg  => 'new',
    coerce    => quote_sub(q( MT::ConvertDB::DBConfig->new( $_[0] ); )),
    required  => 1,
    predicate => 1,
);

sub _trigger_read_only {
    my $self = shift;
    $self->new_config->read_only(@_) if $self->has_new_config;
}

sub BUILD {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->_trigger_read_only( $self->read_only );
    $self->check_configs();
    ###l4p $l4p->info('INITIALIZATION COMPLETE for '.ref($self));
    $self;
}

{
    no warnings 'once';
    *olddb = \&use_old_database;
    *newdb = \&use_new_database;
}
sub object_summary  { shift->new_config->object_summary() }

sub post_load {
    my $self     = shift;
    my $classobj = shift;

    $self->newdb->post_load( $classobj );

    if ( ref($classobj) eq 'MT::ConvertDB::ClassMgr' ) {
        # Re-load and re-save all blogs/websites to ensure all custom fields migrated
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->info('Reloading and resaving all blogs/websites to get full metadata');
        my $cobjs = $classobj->class_objects([qw( blog website )]);
        foreach my $cobj ( @$cobjs ) {
            my $iter = $self->olddb->load_iter( $cobj );
            while (my $obj = $iter->()) {
                $self->olddb->load_meta( $cobj, $obj );
                $self->newdb->save( $cobj, $obj );
            }
        }
    }
}

sub use_old_database {
    ###l4p $l4p ||= get_logger(); $l4p->debug('Switching to old database');
    $_[0]->old_config->use();
}

sub use_new_database {
    ###l4p $l4p ||= get_logger(); $l4p->debug('Switching to new database');
    $_[0]->new_config->use();
}

sub check_configs {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    my $orig = $self->old_config;
    my $new  = $self->new_config;

    die "Config files are the same: ".$orig->file
        if $orig->file eq $new->file;

    die "App config files are the same: ".$orig->app->{cfg_file}
        if $orig->app->{cfg_file} eq $new->app->{cfg_file};

    die "ObjectDrivers are the same: ".$orig->driver->{dsn}
        if $orig->driver->{dsn} eq $new->driver->{dsn};

    $l4p->debug('@MT::ObjectDriverFactory::drivers: '.p(@MT::ObjectDriverFactory::drivers));
}

1;
