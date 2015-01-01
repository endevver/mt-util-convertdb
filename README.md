# NAME

mt-util-convertdb

# DESCRIPTION

This utility makes it possible to migrate Movable Type data between databases,
regardless of database type. For example, you could use it to backup your MT
data from one MySQL database to another or you could migrate your data to a
completely different database (e.g. Oracle to MySQL).

# SYNOPSIS

convertdb \[-h\] \[long options ...\]

    cd $MT_HOME
    CONVERTDB="plugins/ConvertDB/tools/convertdb --new mt-config-NEW.cgi"

    # Need help??
    $CONVERTDB --usage                              # Show compact usage syntax
    $CONVERTDB --help                               # Show help text
    $CONVERTDB --man                                # Show man page

    # Migration modes
    $CONVERTDB --mode resavesource                  # Prep source DB
    $CONVERTDB --mode migrate                       # Migrate and verify

    # Inspection/verification modes
    $CONVERTDB --mode verify                        # Reverify data
    $CONVERTDB --mode showcounts                    # Compare table counts
    $CONVERTDB --mode checkmeta                     # Check for orphaned/unregistered

    # Metadata cleanup
    $CONVERTDB --mode checkmeta --remove-orphans    # Remove the orphaned
    $CONVERTDB --mode checkmeta --migrate-unknown   # Migrate the unregistered

# OPTIONS

- **--mode: String**

    \[REQUIRED\] Run modes. See the ["MODES"](#modes) section for the list of valid values.

- **--new\_config: String**

    \[REQUIRED\] Use this option to specify the path/filename of the MT config file containing the new database information.  It can be an absolute path or relative to MT\_HOME (e.g. ./mt-config-new.cgi)

- **--old\_config: String**

    Use this to specify the path/filename of the current MT config file.  It defaults to ./mt-config-cgi so you only need to use it if you want to set specific configuration directives which are different than the ones in use in the MT installation.

- **--tables: Array of Strings**

    Use this to specify one or more tables (omitting the `mt_` prefix) to include during execution of the
    specified mode. It works similarly to `--classes` but often shorter and more likely what you want since
    it removes the ambiguity of classed objects (MT::Blog/MT::Website, MT::Entry/MT::Page).

    For example, the following performs migration of ALL objects in the mt\_blog table (which may include
    MT::Blog, MT::Website and MT::Community::Blog objects):

        convertdb --mode migrate --table blog

    Like the `--classes`, `--skip-classes` and `--skip-tables` options, multiple values can be specified
    either as a comma-delimited list or separate options and the option name can be singularized for
    readability. For example, the following are equivalent:

            --table blog --table author --table entry
            --tables blog,author,entry

    Also note, like the `--classes` option, any tables contain objects whose class is a parent of the class
    of objects in your specified tables will also be included. For example, the following:

        convertdb --mode migrate --table comment

    ...is exactly the same as this:

        convertdb --mode migrate --tables blog,entry,comment

    This is because MT::Comment objects are children of MT::Entry/MT::Page objects which themselves are
    children of MT::Blog objects. For reasons of data integrity, there is no way to transfer an object
    without its parent object.

- **--skip\_tables: Array of Strings**

    Use this to specify one or more tables to exclude during execution of the specified mode. See the inverse option `--tables` for its value syntax.

    It operates in a similar manner to `--skip_classes` but is often shorter and more likely what you want.
    For example, the following skips the entire mt\_log table:

        --skip-table log

    Unless you need to preserve your Activity Log records or are using the `--classes` or `--tables`
    option, it is recommended to use this option to skip the usually large `mt_log` table, especially under
    **migrate** or **verify** modes:

        --mode migrate --skip-table log
        --mode verify --skip-table log
        --mode showcounts --skip-table log

    This option is ignored if either `--tables` or `--classes` options are specified.

- **--classes: Array of Strings**

    (**Note:** You should _PROBABLY_ be using the `--tables` option instead.) Use this to specify one or
    more classes you want to act on in the specified mode. This is useful if you want to execute a particular
    mode on a one or a few classes of objects. For example:

        --mode migrate --class MT::Template
        --mode showcounts --classes MT::Author,MT::Template

    See the `--tables` option for information on this options multiple-value syntax and parent class
    inclusion.

- **--skip\_classes: Array of Strings**

    (**Note:** You should _PROBABLY_ be using the `--skip-tables` option instead.) Use this to specify one
    or more classes to exclude during execution of the specified mode. It is the exact inverse of the
    `--classes` option and similar to the `--skip-tables` option.

    This option is ignored if either `--tables` or `--classes` options are specified.

- **--no\_verify:**

    \[**migrate MODE ONLY**\] This option skips the content and encoding verification for each object migrated
    to the source database. This is useful if you want to quickly perform a migration and are confident of
    the process or plan on verifying later.

- **--migrate\_unknown:**

    \[**checkmeta MODE ONLY**\] This option cause all metadata records with
    unregistered field types to be migrated. This step now occurs during migrate
    mode so there should be no need to run it separately.'

- **--remove\_orphans:**

    \[**checkmeta MODE ONLY**\] This removes all metadata records from the source database which are associated with a non-existent object.

- **--usage:**

    show a short help message

- **-h --help:**

    show a help message

- **--man:**

    show the manual

# MODES

convertdb's run mode is specified using the `--mode` option (see ["OPTIONS"](#options)).
All values are case-insensitive and the word separator can be a hyphen, an
underscore or omitted entirely (checkmeta, check-meta, check\_meta, CheckMeta,
etc)

All of the modes described below iterate over a master list of all object
classes (and their respective metadata classes and tables) in use by Movable
Type. You can modify this list using `--classes`, `--skip-classes` and
`--skip-tables`. This is extremely useful for acting on all but a few large
tables or performing a mode only on a single or handful of classes/tables.

## Supported Modes

The following is a list of all supported values for the `--mode` flag:

- **resave\_source**

    Iteratively load each object of the specified class(es) from the source database
    (in all/included classes minus excluded) and then resave them back to the
    source database. Doing this cleans up all of the metadata records which have
    null values and throw off the counts.

    This is one of only two modes which affect the source database (the other is
    `--mode checkmeta --remove-orphans`) and it only needs to be run once. It is
    most efficient to execute this mode first in order to clean up the table counts
    for later verification.

- **check\_meta**

    Perform extra verification steps on metadata tables for the specified class(es)
    looking for orphaned and unused metadata rows. With other flags, you can remove
    or even migrate the found rows. It is highly recommended to run this with
    `--remove-orphans` and `--migrate-unknown` flags described later.

- **migrate**

    Iteratively loads each object of the specified class(es) and its associated
    metadata from the source database and saves all of it to the target database.

    By default, the utility also performs an additional step in verifying that the
    data loaded from the source and re-loaded from the target is exactly the same,
    both in content and encoding. If you wish to skip this verification step you
    can use the `--no-verify` flag.

    We highly recommend you use `--skip-table=log` unless you need to preserve the
    activity log history because it can easily dwarf the actual user-created
    content in the database.

- **verify**

    Performs the same verification normally performed by default under migrate
    mode, only without the data migration. This is the exact opposite of `--mode
    migrate --no-verify`.

- **show\_counts**

    Shows the object and metadata table counts for the specified class(es) in both
    the current and new database.

# INSTALLATION

You can download an archived version of this utility from
\[Github/endevver/mt-util-convertdb\](https://github.com/endevver/mt-util-convertdb) or use git:

        $ cd $MT_HOME;
        $ git clone git@github.com:endevver/mt-util-convertdb.git plugins/ConvertDB

Due to a silly little quirk in Movable Type, the utility must be installed as
\`plugins/ConvertDB\` and not \`plugins/mt-util-convertdb\` as is the default.

## DEPENDENCIES

- Movable Type 5 or higher
    - Log4MT plugin (use perl5.8.9-compat branch)
    - RetiredFields plugin
- CPAN Modules
    - Class::Load
    - Data::Printer
    - Import::Base
    - List::MoreUtils
    - List::Util
    - Module::Runtime
    - Moo
    - MooX::Options
    - Path::Tiny
    - Scalar::Util
    - Sub::Quote
    - Term::ProgressBar
    - Test::Deep
    - Text::Table
    - ToolSet
    - Try::Tiny
    - Term::Prompt
    - Pod::POM
    - SQL::Abstract
    - Path::Class

# AUTHOR

Jay Allen, Endevver LLC <jay@endevver.com>
