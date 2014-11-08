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
    isa       => quote_sub(q( my ($v) = @_; defined($v) && Scalar::Util::blessed($v) && $v->isa('MT::ConvertDB::DBConfig') or die "new_config is not valid: ".p($v) )),
    coerce    => quote_sub(q( MT::ConvertDB::DBConfig->new( file => $_[0] ); )),
    trigger   => 1,
    predicate => 1,
);

has new_config => (
    is        => 'ro',
    lazy      => 1,
    init_arg  => 'new',
    isa       => quote_sub(q( my ($v) = @_; defined($v) && Scalar::Util::blessed($v) && $v->isa('MT::ConvertDB::DBConfig') or die "new_config is not valid: ".p($v) )),
    coerce    => quote_sub(q( MT::ConvertDB::DBConfig->new( file => $_[0] ); )),
    trigger   => 1,
    required  => 1,
    predicate => 1,
);

sub _trigger_read_only {
    my $self = shift;
    my $val = shift;
    $self->new_config->read_only( $val );
}

sub _build_old_config { './mt-config.cgi' }

sub _trigger_new_config {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->check_configs() if $self->has_old_config;
}

sub _trigger_old_config {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->check_configs() if $self->has_new_config;
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

{
    no warnings 'once';
    *olddb = \&use_old_database;
    *newdb = \&use_new_database;
}

sub use_old_database {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug('Switching to old database');
    $self->old_config->use();
}

sub use_new_database {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug('Switching to new database');
    $self->new_config->use();
}

sub object_summary {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->debug("Forwarding to new_config->object_summary");
    $self->new_config->object_summary();
}

sub post_load {
    my $self     = shift;
    my $classobj = shift;   #  Can be classmgr
    ###l4p $l4p ||= get_logger(); $l4p->debug("Forwarding to newdb->post_load");
    $self->newdb->post_load( $classobj );
}

sub post_load_meta {
    my $self     = shift;
    my $classobj = shift;   #  Can be classmgr
    ###l4p $l4p ||= get_logger(); $l4p->debug("Forwarding to newdb->post_load");
    $self->newdb->post_load( $classobj );
}

1;
