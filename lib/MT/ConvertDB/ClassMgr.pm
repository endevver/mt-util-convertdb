package MT::ConvertDB::ClassMgr;

use MT::ConvertDB::ToolSet;
use vars qw( $l4p );

has object_types => (
    is      => 'lazy',
    isa     => quote_sub(q( my ($v) = @_; ( defined($v) and ref($v) eq 'ARRAY' ) || die "object_types is not an ARRAY ref"; )),
    builder => 1
);

has category_parents => (
    is => 'ro',
    isa => quote_sub(q(ref $_[0] eq 'HASH' or die 'category_parents is not a HASH ref'; )),
    default => sub { {} },
);

has object_keys => (
    is => 'rw',
    isa => quote_sub(q(
        ref $_[0] eq 'HASH' or die 'category_parents is not a HASH ref';
    )),
    default => sub { {} },
);

has class => (
    is      => 'lazy',
    isa     => quote_sub(q( defined($_[0]) or die "class not defined";  )),
    trigger => 1,
);

has type => (
    is => 'ro',
    isa => quote_sub(q( defined($_[0]) or die "type not defined";  )),
);

has class_hierarchy => (
    is => 'lazy',
);

has metacolumns => (
    is        => 'lazy',
    predicate => 1,
    clearer   => 1,
);

sub _build_metacolumns {
    my $self = shift;
    require MT::Meta;
    my @metacolumns = MT::Meta->metadata_by_class($self->class);
    @metacolumns ? \@metacolumns : undef;
}

sub _trigger_class {
    my $self = shift;
    my $class = shift;
    $self->clear_metacolumns unless defined $self->metacolumns;
}

sub _build_class {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    my $type = $self->type or return;
    MT->model($type);
}

sub _build_object_types {
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    [ keys %{MT->instance->registry('object_types')} ];
}

sub _build_class_hierarchy {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

    my $types = $self->object_types;

    my $class_map = {};
    foreach my $type ( @$types ) {
        my $class = MT->model($type);
        next if $class_map->{$class}{processed}++;
        my $props = $class->properties;
        $l4p->info("Mapping $class");

        unless ($props->{child_classes}) {
            $class_map->{$class}{children} = [];
            $class_map->{$class}{counts}{children} = 0;
            $class_map->{$class}{parents}  ||= {};
            $class_map->{$class}{counts}{parents} = 0;
            $class_map->{$class}{processed} = 1;
            next;
        }

        $class_map->{$class}{parents}  ||= {};
        $class_map->{$class}{children} ||= {};

        if (ref($props->{child_classes}) eq 'ARRAY') {
            $class_map->{$class}{children}{$_} = 1 for @{$props->{child_classes}};
        }
        elsif (ref($props->{child_classes}) eq 'HASH') {
            $class_map->{$class}{children}{$_} = 1 for keys %{$props->{child_classes}};
        }
        else {
            warn "child_classes not an array or hash ref";
            p($props);
            p($props->{child_classes});
            $class_map->{$class}{processed} = 1;
            next;
        }
        $class_map->{$class}{children}         = [ keys %{$class_map->{$class}{children}} ];
        $class_map->{$class}{counts}{children} = scalar @{$class_map->{$class}{children}};

        foreach my $child ( @{$class_map->{$class}{children}} ) {
            $class_map->{$child}{parents} ||= {};
            $class_map->{$child}{parents}{$class} = 1;
        }
    }

    foreach my $class ( keys %$class_map ) {
        $class_map->{$class}{parents}         = [ keys %{$class_map->{$class}{parents}} ];
        $class_map->{$class}{counts}{parents} = scalar @{$class_map->{$class}{parents}};
    }

    ###l4p $l4p->debug('Class map: '.p($class_map));

    return $class_map;

    # my @order = sort { $a->[1]{counts}{parents} <=> $b->[1]{counts}{parents} }
    #              map { [ $_ => $class_map->{$_} ] } keys %$class_map;
    #
    # p(@order);
    # return \@order;
}

my %class_objects_generated;

sub class_objects {
    my $self  = shift;
    my $types = shift // $self->object_types;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

    my @objs;
    push(@objs, $self->class_object('CustomFields::Field'));
    push(@objs, $self->class_object('MT::PluginData'));

    foreach my $type ( @$types ) {
        my $class = MT->model($type);
        push( @objs, $self->class_object($class) );
    }
    return \@objs;
}

sub class_object {
    my $self  = shift;
    my $class = shift;
    return if $class_objects_generated{$class}++;
    $l4p->debug("Generating class object for $class");

    my $class_hierarchy = $self->class_hierarchy;

    my @objs;
    push( @objs, $self->class_object($_) )
        foreach @{ $class_hierarchy->{$class}{parents} };

    (my $class_objclass = $class) =~ s{^MT}{ref($self)}e;
    my $obj = try {
        $class_objclass->new( class => $class );
    }
    catch {
        $class_objclass = ref($self).'::Generic';
        $class_objclass->new( class => $class );
    }
    finally {
        $l4p->info("Using $class_objclass for $class objects");
    };
    push(@objs, $obj);
    return @objs;
}

# sub remove_all { shift->class->remove_all() }
sub remove_all {
    my $self  = shift;
    my $class = $self->class;
    my $count = $class->count(@_);
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Removing %d %s objects (%s)', $count, $class, ref($self) ));
    $self->class->remove_all() if $count;
}

# sub load       { shift->class->load(@_) }
sub load       {
    my $self  = shift;
    my $class = $self->class;
    my $count = $class->count(@_);
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Loading %d %s objects (%s)', $count, $class, ref($self) ));
    $self->class->load(@_)
}

# sub load_iter  {
sub load_iter  {
    my $self = shift;
    my $class = $self->class;
    my $count = $class->count(@_);
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Getting iter for %d %s objects (%s)', $count, $class, ref($self) ));
    my $iter = $self->class->load_iter(@_)
}

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug(sprintf( 'before save for %s%s',
    ###l4p     $self->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )));
    my $defs = $obj->column_defs;

    foreach my $col (keys %{$defs}) {
        my $def = $defs->{$col};
        if ($def->{type} =~ /(?:integer|smallint)/ && $obj->$col) {
            my $val = $obj->$col;
            if ($val =~ /\D/) {
                $val =~ s/\D//g;
                $obj->$col($val);
            }
        }
        if ($def->{type} =~ /(?:string)/ && $obj->$col) {
            require MT::I18N;
            my $val = $obj->$col;
            if (MT::I18N::length_text($val) > $def->{size}) {
                $obj->$col(MT::I18N::substr_text($val,0,$def->{size}));
            }
        }
    }
};

sub save {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf( 'Saving %s%s', $self->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )
    ###l4p ));

    unless ($obj->save) {
        $l4p->error("Failed to save record for class ".$self->class
                     . ": " . ($obj->errstr||'UNKNOWN ERROR'));
        $l4p->error('Object: '.p($obj));
        exit 1;
    }

    return $obj;
}

after save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug(sprintf( 'after save for %s%s',
    ###l4p     $self->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )));
    # ##l4p $l4p->warn('after save is unimplemented');    ### FIXME after save is unimplemented
};

sub post_load {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    my $cat_parent = $self->category_parents;
    # fix up the category parents
    foreach my $id (keys %$cat_parent) {
        my $cat = MT::Category->load($id);
        $cat->parent( $cat_parent->{$id} );
        $cat->save;
    }

    MT->instance->{cfg}->SchemaVersion(MT->schema_version(), 1);
    MT->instance->{cfg}->save_config();
}

sub post_load_meta {
    my $self     = shift;
    ###l4p $l4p ||= get_logger();
    # ##l4p $l4p->warn('post_load_meta is unimplemented');    ### FIXME post_load_meta is unimplemented

}

sub load_meta {
    my $self = shift;
    my ( $classobj, $obj ) = @_;
    ###l4p $l4p ||= get_logger();
    # ##l4p $l4p->warn('load_meta is unimplemented');    ### FIXME load_meta is unimplemented

    my $meta;
    # if ( $obj->has_meta ) {
    #     $obj->meta_obj->refresh();
    #     $obj->init_meta();
    #     my @objs = $obj->meta_obj->load_objects();
    #     # p($obj);
    #     p(@objs);
    #     require MT::Meta;
    #     my @metacolumns = MT::Meta->metadata_by_class(ref($obj));
    #     my %data = map { my $v = $obj->$_ || $obj->meta($_) || CustomFields::Util::get_meta($obj,$_) || undef; ($_ => $v) } map {$_->{name} } @metacolumns;
    #     p(%data) if keys %data;
    # #     # $obj->meta_obj->load_objects();
    # #     # p($obj);
    # #     # $l4p->info()); # for map { $_->{name} } @metacolumns;
    # #     # $l4p->info(ref($obj).' object has meta');
    # #     # $obj->inflate;
    # #     # p( $obj->properties);
    # }
    #
    # # if ( $obj->has_summary ) {
    # #     $l4p->info(ref($obj).' object has summary');
    # #     $obj->meta_obj->load_objects;
    # #     p( $obj);
    # #     # push( @objs, $self->class_object($class->meta_pkg('summary')) );
    # #     # p($class->properties);
    # #     # push( @objs, $self->class_object($class->meta_pkg) );
    # # }

    return $meta;
}

sub save_meta {
    my $self = shift;
    my ( $classobj, $obj, $meta ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    # ##l4p $l4p->warn('save_meta is unimplemented');    ### FIXME save_meta is unimplemented
    return $meta;
}

#############################################################################

package MT::ConvertDB::ClassMgr::CustomField::Fields;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

};

after save => sub {
    my ( $self, $obj ) = @_;
    $obj->add_meta;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Template;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

    my $object_keys = $self->object_keys;

    ## Look for duplicate template names, because
    ## we have uniqueness constraints in the DB.
    my $key = $obj->blog_id . ':' . lc($obj->name);
    if ($object_keys->{$key}++) {
        print "        Found duplicate template name '" .
              $obj->name;
        $obj->name($obj->name . ' ' . $object_keys->{$key});
        print "'; renaming to '" . $obj->name . "'\n";
    }
    ## Touch the text column to make sure we read in
    ## any linked templates.
    my $text = $obj->text;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Author;

use MT::Util;
use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    my $class       = $self->class;
    my $object_keys = $self->object_keys;

    ## Look for duplicate author names, because
    ## we have uniqueness constraints in the DB.
    my $key = lc($obj->name || $obj->basename || MT::Util::make_unique_author_basename($obj));
    if ($object_keys->{$class . $obj->type}{$key}++) {
        my $orig = $obj->name;
        $obj->name(join(' ', $obj->name, $object_keys->{$class . $obj->type}{$key}));
        $l4p->warn('Found duplicate author name '.$orig.'; renaming to '.$obj->name);
    }
    $obj->email('') unless defined $obj->email;
    $obj->set_password('') unless defined $obj->password;
};


#############################################################################

package MT::ConvertDB::ClassMgr::Comment;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    $obj->visible(1) unless defined $obj->visible;
};

#############################################################################

package MT::ConvertDB::ClassMgr::TBPing;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    $obj->visible(1) unless defined $obj->visible;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Category;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    my $object_keys = $self->object_keys;

    ## Look for duplicate category names, because
    ## we have uniqueness constraints in the DB.
    my $key = lc($obj->label) . $obj->blog_id;
    if ($object_keys->{$key}++) {
        print "        Found duplicate category label '" .
              $obj->label;
        $obj->label($obj->label . ' ' . $object_keys->{$key});
        print "'; renaming to '" . $obj->label . "'\n";
    }
    # save the parent value for assignment at the end
    if ($obj->parent) {
        my $cat_parent = $self->category_parents;
        $cat_parent->{$obj->id} = $obj->parent;
        $obj->parent(0);
    }
};

#############################################################################

package MT::ConvertDB::ClassMgr::Trackback;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    $obj->entry_id(0) unless defined $obj->entry_id;
    $obj->category_id(0) unless defined $obj->category_id;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Entry;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

before save => sub {
    my ( $self, $obj ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    $obj->allow_pings(0)
        if defined $obj->allow_pings && $obj->allow_pings eq '';
    $obj->allow_comments(0)
        if defined $obj->allow_comments && $obj->allow_comments eq '';
};

#############################################################################

package MT::ConvertDB::ClassMgr::Generic;

use MT::ConvertDB::Base 'Class';
extends 'MT::ConvertDB::ClassMgr';
use vars qw( $l4p );

1;
