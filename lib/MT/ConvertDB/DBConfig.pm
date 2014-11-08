package MT::ConvertDB::DBConfig;

use MT::ConvertDB::ToolSet;
use Class::Load qw( load_class );
use vars qw( $l4p );

has read_only => (
    is        => 'rw',
    default   => 1,
    trigger   => 1,
    predicate => 1,
);

has app_class => (
    is      => 'ro',
    default => 'MT::App::CMS',
);

has file => (
    is        => 'ro',
    coerce    => quote_sub(q( path($_[0])->absolute )),
    isa       => quote_sub(q( my ($v) = @_; defined($v) && Scalar::Util::blessed($v) && $v->isa('Path::Tiny') && $v->is_file or die "file is not a valid config file path: ".$v )),
    predicate => 1,
);

has app => (
    is      => 'lazy',
    isa     => quote_sub(q( my ($v) = @_; Scalar::Util::blessed($v) && $v->isa('MT') or die "Bad app: ".p($v) )),
    trigger => 1,
);

has driver => (
    is        => 'lazy',
    isa       => quote_sub(q( my ($v) = @_; Scalar::Util::blessed($v) &&
$v->isa('MT::ObjectDriver::Driver::DBI') or die "Bad driver: ".p($v) )),
    predicate => 1,
);

has obj_summary => (
    is      => 'ro',
    default => sub { {} },
);

sub BUILDARGS {
    my ( $class, @args ) = @_;
    unshift @args, "file" if @args % 2 == 1;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info('########## Instantiation for config '.$_[1] );
    return { @args };
}

sub BUILD {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->app;
    $self->driver;
    $self->finish_init;
    ###l4p $l4p->info('INITIALIZATION COMPLETE for '.ref($self).': '.$self->label);
    $self;
}

sub _trigger_read_only {
    my $self = shift;
    my $val  = shift;
    ###l4p $l4p->info(sprintf('Setting %s to %s', $self->driver->{dsn},
    ###l4p     $val ? 'READ ONLY' : 'WRITEABLE' )) if $val != $self->read_only;
}

sub _build_app {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my $app_class = $self->app_class;
    my $cfg_file  = $self->file->absolute;
    ###l4p $l4p->info("Constructing new app: $app_class");
    ###l4p $l4p->info('A previous app existed: '.$MT::mt_inst) if $MT::mt_inst;
    ###l4p $l4p->info('A previous config existed: '.$MT::ConfigMgr::cfg) if $MT::ConfigMgr::cfg;
    ### FIXME Previous app isa MT, not MT::App::CMS

    my $mt = try {
        local $SIG{__WARN__} = sub {};
        no warnings 'once';
        load_class($app_class);
        undef $MT::ConfigMgr::cfg;
        undef $MT::mt_inst;
        $ENV{MT_CONFIG} = $MT::CFG_FILE = $cfg_file;
        $MT::MT_DIR     = $MT::APP_DIR  = $MT::CFG_DIR = $ENV{MT_HOME};
        bless {}, $app_class;
    }
    catch {
        $l4p->logcroak("Could not initialize app: $_");
        return undef;
    };

    $mt->bootstrap();
    $mt->{mt_dir}     = $MT::MT_DIR;
    $mt->{config_dir} = $MT::CFG_DIR;
    $mt->{app_dir}    = $MT::APP_DIR;

    my $cs            = MT->component('core')->{registry}{config_settings};
    $cs->{DBIRaiseError}{default}      = 1;
    $cs->{DisableObjectCache}{default} = 1;
    $cs->{PluginSwitch}{default}       = { 'LDAPTools' => 0 };

    $mt->init_callbacks();

    ## Initialize the language to the default in case any errors occur in
    ## the rest of the initialization process.
    $mt->init_config({ Config => $cfg_file }) or return;

    $l4p->logcroak('Config is not defined!') unless $mt->{cfg};
    $l4p->logcroak("Config is wrong! \$cfg_file=$cfg_file, \$mt->{cfg_file}=".$mt->{cfg_file})
        unless $mt->{cfg_file} eq $cfg_file->absolute;

    return $mt;
}

sub _build_driver {
    my $self = shift;
    my $mt   = $self->app;
    my $cfg  = $mt->{cfg};
    ###l4p $l4p ||= get_logger();

    # Undef package variables which will cache any previous config's values
    require MT::Object;
    require MT::ObjectDriverFactory;
    {
        no warnings 'once';
        undef $MT::Object::DRIVER;
        undef $MT::ObjectDriverFactory::DRIVER;
        undef $MT::ObjectDriverFactory::dbd_class;
    }

    # Avoid ObjectDriverFactory->instance and force the driver to
    # use the fallback non-caching DBI driver for this config
    my $pwd    = $cfg->DBPassword;
    my $uname  = $cfg->DBUser;
    my $dbd    = MT::ObjectDriverFactory->dbd_class;

    my $driver = MT::ObjectDriver::Driver::DBI->new(
        dbd       => $dbd,
        dsn       => $dbd->dsn_from_config($cfg),
        reuse_dbh => 1,
        ( $uname ? ( username => $uname ) : () ),
        ( $pwd   ? ( password => $pwd )   : () ),
    );

    ###l4p $l4p->info('Objectdriver configured: '.$driver->{dsn});
    no warnings 'once';
    push( @MT::ObjectDriverFactory::drivers, $driver );
    return ( $MT::Object::DRIVER = $MT::ObjectDriverFactory::DRIVER = $driver );
}

sub finish_init {
    my $self = shift;
    my $mt   = $self->app;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info('Finishing initialization');
    my @app_args = my(%param) = ( Config => $self->file.'' );

    $mt->init_lang_defaults(@app_args) or return;
    $mt->config->read_config($self->file);
    require MT::Plugin;
    $mt->init_addons(@app_args) or return;
    $mt->init_config_from_db( \%param ) or return;
    $mt->init_debug_mode;
    $mt->init_plugins(@app_args) or return;
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

    $self->check_plugins();

    $mt->run_callbacks( 'init_app', $mt );

    $self->check_schema();
}

sub check_plugins {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info('Checking loaded plugins');
    ###l4p if ( $l4p->is_debug ) { my $pkeys = [sort keys %MT::Plugins]; $l4p->debug(p($pkeys)); }

    # Check that certain plugins are loaded:
    #   * ConfigAssistant
    #   * CustomFields
    #   * Others?
    %MT::Plugins or $l4p->logcroak('%MT::Plugins not loaded');

    exists( $MT::Plugins{$_} ) || $l4p->logcroak("$_ not loaded")
        for qw( Commercial.pack ConfigAssistant.pack );

    my $cpack = $MT::Plugins{'Commercial.pack'};
    # p($cpack);
    $l4p->logcroak('CustomFields not loaded')
        unless $cpack
            && exists( $cpack->{object}{customfields} )
            && @{ $cpack->{object}{customfields} } > 0;

    # Check that certain plugins are NOT loaded
    #   * LDAPTools
    #   * Others?
    exists($MT::Plugins{LDAPTools}) && exists($MT::Plugins{LDAPTools}{object})
        and $l4p->logcroak( 'The LDAPTools plugin conflicts with this tool. '
                          . 'Please remove it from the plugins directory '
                          . 'and re-run');

  # p($MT::Plugins{'GenentechThemePack'}->{object}{registry});
    # Initialize plugins?
    #   * CustomFields
    #   * ConfigAssistant
    #   * Others?
    # require ConfigAssistant::Init;
    # ConfigAssistant::Init::init_app($MT::Plugins{'ConfigAssistant.pack'}{object}, $self->app);
}

sub check_schema {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    require MT::Upgrade;
    ###l4p $l4p->info('Loading/checking database schema');
    MT::Upgrade->do_upgrade(Install => 1) or die MT::Upgrade->errstr;
}

sub use {
    my $self   = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    no warnings 'once';
    MT->instance->set_instance( $self->app );
    $MT::ConfigMgr::cfg              = $self->app->{cfg};
    $MT::ObjectDriverFactory::DRIVER = $MT::Object::DRIVER = $self->driver;
    $self;
}

sub load            { shift; shift->load(@_)         }
sub load_iter       { shift; shift->load_iter(@_)    }
sub load_meta       { shift; shift->load_meta(@_)    }
sub post_load       { shift; shift->post_load()      }
sub post_load_meta  { shift; shift->post_load_meta() }
sub object_summary  { p(shift->obj_summary)          }

sub save_meta       {
    my $self = shift;
    return shift->save_meta(@_) unless $self->read_only;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('FAKE saving metadata for %s%s',
    ###l4p     $classobj->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' ) ));
}

sub remove_all  {
    my $self     = shift;
    my $classobj = shift;
    return $classobj->remove_all() unless $self->read_only;
    ###l4p $l4p ||= get_logger();
    my $class = $classobj->class;
    my $count = $class->count(@_);
    ###l4p $l4p->info(sprintf('FAKE Removing %d %s objects (%s)', $count, $class, ref($classobj) ));
}

before save => sub {
    my $self               = shift;
    my ( $classobj, $obj ) = @_;
    # ##l4p $l4p ||= get_logger(); $l4p->warn('before save is unimplemented');    ### FIXME before save is unimplemented

};

sub save {
    my $self = shift;
    my ( $classobj, $obj ) = @_;
    ###l4p $l4p ||= get_logger();

    my $object_summary = $self->obj_summary;
    $object_summary->{total}{$classobj->class}++;
    $object_summary->{meta}{$classobj->class}++ if $obj->has_meta;

    return $classobj->save( $obj ) unless $self->read_only;

    ###l4p $l4p->info(sprintf('FAKE saving %s%s',
    ###l4p     $classobj->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' ) ));
}

after save => sub {
    my $self               = shift;
    my ( $classobj, $obj ) = @_;
    # ##l4p $l4p ||= get_logger(); $l4p->warn('after save is unimplemented');    ### FIXME after save is unimplemented
};

sub label {
    my $self = shift;
    join(' ', '[',
              ($self->has_file      ? $self->file->basename : ()),
              ($self->has_driver    ? $self->driver->{dsn}  : ()),
              ($self->read_only     ? 'READ ONLY' : 'WRITEABLE' ),
              ']'
    );
}

1;