package MT::ConvertDB::DBConfig;

use MT::ConvertDB::ToolSet;
use vars qw( $l4p );

has read_only => (
    is        => 'rw',
    lazy      => 1,
    default   => 1,
    trigger   => 1,
    predicate => 1,
);

has needs_install => (
    is        => 'rw',
    default   => 0,
    clearer   => 1,
);

has app_class => (
    is      => 'ro',
    default => 'MT::App::CMS',
);

has file => (
    is     => 'ro',
    coerce => quote_sub(q( path($_[0])->absolute )),
    isa    => quote_sub(
        q( my ($v) = @_; defined($v) && Scalar::Util::blessed($v) && $v->isa('Path::Tiny') && $v->is_file or die "file is not a valid config file path: ".$v )
    ),
    predicate => 1,
);

has app => (
    is  => 'lazy',
    isa => quote_sub(
        q( my ($v) = @_; Scalar::Util::blessed($v) && $v->isa('MT') or die "Bad app: ".p($v) )
    ),
    trigger => 1,
);

has driver => (
    is  => 'lazy',
    isa => quote_sub(
        q( my ($v) = @_; Scalar::Util::blessed($v) &&
$v->isa('MT::ObjectDriver::Driver::DBI') or die "Bad driver: ".p($v) )
    ),
    predicate => 1,
);

has [qw( obj_counts )] => (
    is      => 'ro',
    default => sub { {} },
);

sub BUILDARGS {
    my ( $class, @args ) = @_;
    unshift @args, "file" if @args % 2 == 1;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info('#'x10, " Instantiation for config $args[1] ", '#'x10 );
    return { @args };
}

sub BUILD {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->app && $self->driver && $self->finish_init;
    ###l4p $l4p->info('INITIALIZATION COMPLETE for '.$self->label);
    return $self;
}

sub _trigger_read_only {
    my $self = shift;
    my $val  = shift;
    ###l4p $l4p ||= get_logger();
        ###l4p $l4p->info(sprintf('Driver dbh for %s set to %s', $self->label,
        ###l4p     $val ? 'READ ONLY' : 'WRITEABLE' ));
}

sub _build_app {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my $app_class = $self->app_class;
    my $cfg_file  = $self->file->absolute;
    ###l4p $l4p->info("Constructing new app: $app_class");
    ###l4p $l4p->debug('A previous app existed: '.$MT::mt_inst) if $MT::mt_inst;
    ###l4p $l4p->debug('A previous config existed: '.$MT::ConfigMgr::cfg) if $MT::ConfigMgr::cfg;

    my $mt = try {
        local $SIG{__WARN__} = sub { };
        no warnings 'once';
        use_module($app_class);
        undef $MT::ConfigMgr::cfg;
        undef $MT::mt_inst;
        $ENV{MT_CONFIG} = $MT::CFG_FILE = $cfg_file;
        $MT::MT_DIR = $MT::APP_DIR = $MT::CFG_DIR = $ENV{MT_HOME};
        MT->set_instance( bless {}, $app_class );
    }
    catch {
        $l4p->logcroak("Could not initialize app: $_");
        return undef;
    };

    $mt->bootstrap();
    $mt->{mt_dir}     = $MT::MT_DIR;
    $mt->{config_dir} = $MT::CFG_DIR;
    $mt->{app_dir}    = $MT::APP_DIR;

    my $cs = MT->component('core')->{registry}{config_settings};
    $cs->{DBIRaiseError}{default}      = 1;
    $cs->{DisableObjectCache}{default} = 1;
    $cs->{PluginSwitch}{default}       = { 'LDAPTools' => 0 };

    $mt->init_callbacks();

    ## Initialize the language to the default in case any errors occur in
    ## the rest of the initialization process.
    $mt->init_config( { Config => $cfg_file } ) or return;

    $l4p->logcroak('Config is not defined!') unless $mt->{cfg};
    $l4p->logcroak( "Config is wrong! \$cfg_file=$cfg_file, \$mt->{cfg_file}="
            . $mt->{cfg_file} )
        unless $mt->{cfg_file} eq $cfg_file->absolute;

    return $mt;
}

sub _build_driver {
    my $self = shift;
    my $mt   = $self->app;
    my $cfg  = $mt->{cfg};
    ###l4p $l4p ||= get_logger();

    $self->reset_object_drivers();

    # Avoid ObjectDriverFactory->instance and force the driver to
    # use the fallback non-caching DBI driver for this config
    my $pwd   = $cfg->DBPassword;
    my $uname = $cfg->DBUser;
    my $dbd   = MT::ObjectDriverFactory->dbd_class;

    my $driver = MT::ObjectDriver::Driver::DBI->new(
        dbd       => $dbd,
        dsn       => $dbd->dsn_from_config($cfg),
        reuse_dbh => 1,
        ( $uname ? ( username => $uname ) : () ),
        ( $pwd   ? ( password => $pwd )   : () ),
    );

    unless ( $driver->table_exists(MT->model('config')) ) {
        $l4p->info(sprintf( 'Schema init required for dsn in %s: %s',
                            $self->file->basename, $driver->{dsn} ) );
        $self->read_only(0) if $self->read_only;
        $self->needs_install(1);
    }

    ###l4p $l4p->info('Objectdriver configured: '.$driver->{dsn});
    no warnings 'once';
    push( @MT::ObjectDriverFactory::drivers, $driver );
    return ( $MT::Object::DRIVER = $MT::ObjectDriverFactory::DRIVER
            = $driver );
}

sub finish_init {
    my $self = shift;
    my $mt   = $self->app;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info('Finishing initialization');
    my @app_args = my (%param) = ( Config => $self->file . '' );

    $mt->init_lang_defaults(@app_args)
        or confess('init_lang_defaults returned false');
    $mt->config->read_config( $self->file );
    require MT::Plugin;
    $mt->init_addons(@app_args)
        or confess('init_addons returned false');
    $mt->init_config_from_db( \%param )
        or confess('init_config_from_db returned false');
    $mt->init_debug_mode;
    $mt->init_plugins(@app_args)
        or confess('init_plugins returned false');
    {
        no warnings 'once';
        $MT::plugins_installed = 1;
    }
    $mt->init_schema();
    $mt->init_permissions();

    # Load MT::Log so constants are available
    require MT::Log;

    $mt->run_callbacks( 'post_init', $mt, \%param );

    $mt->{is_admin}             = 0;
    $mt->{template_dir}         = 'cms';          #$app->id;
    $mt->{user_class}           = 'MT::Author';
    $mt->{plugin_template_path} = 'tmpl';
}

sub check_plugins {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->info('Checking loaded plugins');
    ###l4p if ( $l4p->is_debug ) { my $pkeys = [sort keys %MT::Plugins]; $l4p->debug(p($pkeys)); }

    # Check that certain plugins are loaded:
    %MT::Plugins or $l4p->logcroak('%MT::Plugins not loaded');

    exists( $MT::Plugins{$_} )
        || $l4p->logcroak( "$_ not loaded: ",
        l4mtdump( [ keys %MT::Plugins ] ) )
        for qw( Commercial.pack ConfigAssistant.pack );

    my $cpack = $MT::Plugins{'Commercial.pack'};
    $l4p->logwarn('CustomFields not loaded')
        unless $cpack
        && exists( $cpack->{object}{customfields} )
        && @{ $cpack->{object}{customfields} } > 0;

    # Check that certain plugins are NOT loaded
    exists( $MT::Plugins{LDAPTools} )
        && exists( $MT::Plugins{LDAPTools}{object} )
        and $l4p->logdie( 'The LDAPTools plugin conflicts with this tool. '
            . 'Please remove it from the plugins directory '
            . 'and re-run');
}

sub check_schema {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Checking schema for %s', $self->label,
    ###l4p     $self->needs_install ? 'NEEDS INSTALL' : ''));

    $self->reset_object_drivers();

    my $dbh = $self->driver->rw_handle;
    local $dbh->{RaiseError} = 0;  # Upgrade doesn't handle its own exceptions
    local $SIG{__WARN__} = sub { $l4p->warn(@_) }; # Re-route warnings

    require MT::Upgrade;
    MT::Upgrade->do_upgrade( CLI => 1, Install => $self->needs_install )
        or die MT::Upgrade->errstr;

    $self->clear_needs_install;
    return 1;
}

sub reset_object_drivers {
    my $self   = shift;
    my $driver = shift || ( $self->has_driver ? $self->driver : undef );
    # Undef cached MT::Object and MT::ObjectDriverFactory package variables
    require MT::Object;
    require MT::ObjectDriverFactory;
    no warnings 'once';
    $MT::ObjectDriverFactory::DRIVER    = $MT::Object::DRIVER = $driver;
    $MT::ObjectDriverFactory::dbd_class = $driver ? $driver->dbd : undef;
}

sub use {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    no warnings 'once';
    MT->set_instance( $self->app );
    $MT::ConfigMgr::cfg = $self->app->{cfg};
    $self->reset_object_drivers();
    $self;
}

sub load               { shift; shift->load(@_) }
sub load_object        { shift; shift->load_object(@_) }
sub load_iter          { shift; shift->load_iter(@_) }
sub load_meta          { shift; shift->load_meta(@_) }
sub post_migrate       { shift; shift->post_migrate(@_) }
sub post_migrate_class { shift; shift->post_migrate_class(@_) }

sub clear_counts {
    my $self     = shift;
    my $classobj = shift;
    my $ds       = $classobj->class->datasource;
    delete $self->obj_counts->{$ds} if $self->obj_counts->{$ds};
}

sub count {
    my $self     = shift;
    my $classobj = shift;
    my $ds       = $classobj->class->datasource;
    return $self->obj_counts->{$ds}{object} //= $classobj->count(@_);
}

sub meta_count {
    my $self     = shift;
    my $classobj = shift;
    my $ds       = $classobj->class->datasource;
    return $self->obj_counts->{$ds}{meta} //= $classobj->meta_count(@_);
}

sub table_counts {
    my $self     = shift;
    my $classobj = shift;
    my $class    = $classobj->class;
    $self->clear_counts($classobj);

    my $tally = {
        object => $self->count($classobj, @_),
        meta   => $self->meta_count($classobj),
    };
    delete $tally->{meta} unless defined $tally->{meta};

    $tally->{total} += $_ for values %$tally;

    return $tally;
}

sub remove_all {
    my $self     = shift;
    my $classobj = shift;
    my $class    = $classobj->class;
    ###l4p $l4p ||= get_logger();
    return if $self->read_only;

    $self->clear_counts($classobj);
    return $classobj->remove_all();
}

sub save {
    my $self = shift;
    my ( $classobj, $obj, $meta ) = @_;
    ###l4p $l4p ||= get_logger();

    return $classobj->save($obj) unless $self->read_only;

    ###l4p $l4p->debug(sprintf('FAKE saving %s%s',
    ###l4p     $classobj->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' ) ));
}

sub label {
    my $self     = shift;
    my $file     = $self->has_file ? $self->file->basename : '';
    my $readonly = $self->read_only ? 'READ ONLY' : 'WRITEABLE';
    my $dsn      = $self->has_driver ? $self->driver->{dsn} : $self->app->config->Database;
    return "[${file}:${dsn} $readonly]";
}

1;
