package MT::ConvertDB::ConfigMgr;

use Path::Tiny;
use Scalar::Util qw( blessed );
use MT::ConvertDB::Base;
use vars qw( $l4p );

has old_config => (
    is       => 'lazy',
    init_arg => 'old',
    isa      => quote_sub(q(
        my ($v) = @_;
        defined($v) && Scalar::Util::blessed($v) && $v->isa('Path::Tiny') && $v->is_file
            or die "old_config is not a valid config file path: ".$v
    )),
    coerce   => \&_coerce_config,
);

has new_config => (
    is       => 'ro',
    init_arg => 'new',
    isa      => quote_sub(q( my ($v) = @_; defined($v) && Scalar::Util::blessed($v) && $v->isa('Path::Tiny') && $v->is_file or die "new_config is not a valid config file path: ".$v )),
    coerce   => \&_coerce_new_config,
    trigger  => 1,
    required => 1,
);

sub _coerce_new_config {
    ###l4p $l4p ||= get_logger(); $l4p->trace();
    $_[0] || $l4p->error("No new-config specified") && exit;
    _coerce_config(@_);
}

sub _coerce_config {
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    ###l4p $l4p->debug('Coercing '.$_[0]);
    # return unless defined($_[0]);
    (blessed($_[0]) and blessed($_[0]) eq 'Path::Tiny') ? $_[0] : path($_[0]);
}

sub _build_old_config {
    my $self = shift;
    my $arg  = shift() || '.';
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    ###l4p $l4p->debug('Building old config '.$arg);
    my $orig = MT->instance->find_config({ Config => $arg });
    my $new  = $self->new_config;

    if ( $orig eq $new ) {
        print "New and old config files are the same. Aborting...\n";
        exit;
    }
    else {
        print "convert source: $orig\n";   ### FIXME Get rid of this
        print "   destination: $new\n";
    }
    $orig;
}

sub _trigger_new_config {
    my $self = shift;
    my $cfg  = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    ###l4p $l4p->debug('New config set: '.$cfg);

    my $mt = try {
        local $SIG{__WARN__} = sub {};
        require MT;
        MT->new(Config => $cfg) or die MT->errstr;
    };

    if (%MT::Plugins) {
        if ( exists $MT::Plugins{LDAPTools} ) {
            print "ERROR: LDAPTools plugin installed. Please remove the LDAPTools plugin from the plugins directory and re-run\n";
            exit;
        }
        elsif (exists $MT::Plugins{'ConfigAssistant.pack'} ) {
            require ConfigAssistant::Init;
            ConfigAssistant::Init::init_app($MT::Plugins{'ConfigAssistant.pack'}{object}, $mt);
        }
        else {
            print "ERROR: ConfigAssistant.pack not loaded\n";
            exit 1;
        }
    }
    else {
        print "ERROR: \%MT::Plugins not loaded\n";
        exit 1;
    }


    $self->configure_objectdriver($cfg);

    require MT::Upgrade;
    $l4p->info('Loading database schema');
    MT::Upgrade->do_upgrade(Install => 1) or die MT::Upgrade->errstr;
}

sub configure_objectdriver {
    my $self = shift;
    my ($cfg_file) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();
    ###l4p $l4p->debug('Configuring objectdriver '.($cfg_file ? "for $cfg_file" : '' ));
    my $mt  = MT->instance;
    my $cfg = $mt->{cfg};

    require MT::Object;
    require MT::ObjectDriverFactory;
    if ( $cfg_file ) {
        undef $MT::Object::DRIVER;
        undef $MT::ObjectDriverFactory::DRIVER;
        $cfg->read_config($cfg_file) if $cfg_file;
    }

    $cfg->DBIRaiseError(1);

    # Initialize the objectdriver
    my $driver = MT::Object->driver($cfg->ObjectDriver)
        or die MT::ObjectDriver->errstr;

    # Force the driver to use the fallback non-caching DBI driver
    $driver = $MT::ObjectDriverFactory::DRIVER = $MT::Object::DRIVER = $driver->fallback;

    # $l4p->info('Driver: '.p(MT::Object->driver));

    require ConfigAssistant::Init;
    ConfigAssistant::Init::init_options($mt);

    CustomFields::Util->load_meta_fields();

    return $driver;
}

sub use_old_database {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace();
    ###l4p $l4p->debug('Switching to old database');
    $self->configure_objectdriver($self->old_config);
}

sub use_new_database {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace();
    ###l4p $l4p->debug('Switching to new database');
    $self->configure_objectdriver($self->new_config)
}

1;
