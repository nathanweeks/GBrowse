#!/usr/bin/perl -w
# This script checks the schemas and required fields of the Users Database.
use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI;
use Bio::Graphics::Browser2 "open_globals";
use CGI::Session;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use GBrowse::ConfigData;
use List::Util;
use File::Spec;
use File::Path 'remove_tree';
use POSIX 'strftime';

use constant SCHEMA_VERSION => 1;

# First, collect all the flags - or output the correct usage, if none listed.
my ($dsn, $admin);
GetOptions('dsn=s'         => \$dsn,
           'admin=s'       => \$admin) or die <<EOF;
Usage: $0 [options] <optional path to GBrowse.conf>

Initializes an empty GBrowse user accounts and uploads metadata database.
Options:

   -dsn       Provide a custom DBI connection string, overriding what is
              set in Gbrowse.conf. Note that if there are semicolons in the
              string (like most MySQL connection DSNs will), you WILL have
              to escape it with quotes.
   -admin     Provide an administrator username and password (in the form
              'user:pass') to skip the prompts if the database does not
              exist.

Currently mysql and SQLite databases are supported. When creating a
mysql database you must provide the -admin option to specify a user
and password that has database create privileges on the server.
EOF
    ;

# Open the connections.
my $globals = Bio::Graphics::Browser2->open_globals;
$dsn ||= $globals->user_account_db;
if (!$dsn || ($dsn =~ /filesystem|memory/i) || !$globals->user_accounts) {
    print "No need to run database metadata configuration script, filesystem-backend will be used.";
    exit 0;
}

create_database();

my $database = DBI->connect($dsn) 
    or die "Error: Could not open users database, please check your credentials.\n" . DBI->errstr;
my $type = $database->{Driver}->{Name};

my $autoincrement = $type =~ /mysql/i  ? 'auto_increment'
                   :$type =~ /sqlite/i ? 'autoincrement'
                   :'';
my $last_id       = $type =~ /mysql/i  ? 'mysql_insertid'
                   :$type =~ /sqlite/i ? 'last_insert_rowid'
                   :'';

# Database schema. To change the schema, update/add the fields here, and run this script.
my $users_columns = {
    userid      => "integer PRIMARY KEY $autoincrement",
    email       => "varchar(64) not null UNIQUE",
    pass        => "varchar(32) not null",
    remember    => "boolean not null",
    openid_only => "boolean not null",
    confirmed   => "boolean not null",
    cnfrm_code  => "varchar(32) not null",
    last_login  => "timestamp not null",
    created     => "datetime not null"
};

my $session_columns = {
    userid      => "integer PRIMARY KEY $autoincrement",
    username    => "varchar(32)",
    sessionid   => 'char(32) not null UNIQUE',
    uploadsid   => 'char(32) not null UNIQUE',
};

my $openid_columns = {
    userid     => "int(10) not null $autoincrement",
    username   => "varchar(32) not null",
    openid_url => "varchar(128) not null PRIMARY key"
};

my $uploads_columns = {
    trackid           => "varchar(32) not null PRIMARY key",
    userid            => "integer not null UNIQUE",
    path              => "text",
    title             => "text",
    description       => "text",
    imported          => "boolean not null",
    creation_date     => "datetime not null",
    modification_date => "datetime",
    sharing_policy    => "ENUM('private', 'public', 'group', 'casual') not null",
    users             => "text",
    public_users      => "text",
    public_count      => "int",
    data_source       => "text",
 };

my $dbinfo_columns = {
    schema_version    => 'int(10) not null UNIQUE'
};

my $old_users_columns = {
    userid      => "varchar(32) not null UNIQUE PRIMARY KEY",
    uploadsid   => "varchar(32) not null UNIQUE",
    username    => "varchar(32) not null UNIQUE",
    email       => "varchar(64) not null UNIQUE",
    pass        => "varchar(32) not null",
    remember    => "boolean not null",
    openid_only => "boolean not null",
    confirmed   => "boolean not null",
    cnfrm_code  => "varchar(32) not null",
    last_login  => "timestamp not null",
    created     => "datetime not null"
};

my $old_uploads_columns = {
    uploadid          => "varchar(32) not null PRIMARY key",
    userid            => "varchar(32) not null",
    path              => "text",
    title             => "text",
    description       => "text",
    imported          => "boolean not null",
    creation_date     => "datetime not null",
    modification_date => "datetime",
    sharing_policy    => "ENUM('private', 'public', 'group', 'casual') not null",
    users             => "text",
    public_users      => "text",
    public_count      => "int",
    data_source       => "text",
};



fix_permissions() if $type !~ /sqlite/i;

upgrade_schema(SCHEMA_VERSION);
check_table("users",            $users_columns);
check_table("session",          $session_columns);
check_table("openid_users",     $openid_columns);
check_table("uploads",          $uploads_columns);

check_sessions();
check_uploads_ids();
check_all_files();
check_data_sources();
fix_permissions() if $type =~ /sqlite/i;

$database->disconnect;

print STDERR "Done!\n";

exit 0;


# Check Table (Name, Columns) - Makes sure the named table is there and follows the schema needed.
sub check_table {
    my $name    = shift or die "No table name given, please check the gbrowse_metadb_config.pl script.\n";
    my $columns = shift or die "No table schema given, please check the gbrowse_metadb_config.pl script.\n";
    
    # If the database doesn't exist, create it.
    local $database->{PrintError} = 0;
    unless (eval {$database->do("SELECT * FROM $name LIMIT 1")}) {
        $database->{PrintError} = 1;
        print STDERR ucfirst $name . " table didn't exist, creating...\n";
        my @column_descriptors = map { "$_ " . escape_enums($$columns{$_}) } 
	                         keys %$columns; # This simply outputs %columns as "$key $value, ";
        my $creation_sql = "CREATE TABLE $name (" 
	    . (join ", ", @column_descriptors) . ")" 
	    . (($type =~ /mysql/i)? " ENGINE=InnoDB;" : ";");
        $database->do($creation_sql) or die "Could not create $name database.\n";

    }

    # If a required column doesn't exist, add it.
    my $sth = $database->prepare("SELECT * from $name LIMIT 1");
    $sth->execute;
    my %existing_columns  = map {$_=>1} @{$sth->{NAME_lc}};
    my @columns_to_create = grep {!$existing_columns{$_}} keys %$columns;
    my @columns_to_drop   = grep {!$columns->{$_}}        keys %existing_columns;

    if (@columns_to_drop) {
	print STDERR "Dropping the following columns: ",join(',',@columns_to_drop),".\n";
	for my $c (@columns_to_drop) {
	    $database->do("ALTER TABLE $name DROP $c");
	}
    }

    if (@columns_to_create) {
	my $run = 0;
        
	# SQLite doesn't support altering to add multiple columns or ENUMS, 
	# so it gets special treatment.
	if ($type =~ /sqlite/i) {
	    # If we don't find a specific column, add its SQL to the columns_to_create array.
	    foreach (@columns_to_create) {
		$$columns{$_} = escape_enums($$columns{$_});
                
		# Now add each column individually
		unless ((join " ", @{$sth->{NAME_lc}}) =~ /$_/) {
		    my $alter_sql = "ALTER TABLE $name ADD COLUMN $_ " . $$columns{$_} . ";";
		    $database->do($alter_sql) or die "While adding column $_ to $name: ",
		                                      $database->errstr;
		}
	    }
	} else {
	    # If we don't find a specific column, add its SQL to the columns_to_create array.
	    foreach (keys %$columns) {
		unless ((join " ", @{$sth->{NAME_lc}}) =~ /$_/) {
		    push @columns_to_create, "$_ " . $$columns{$_};
		    $run++;
		}
	    }
            
	    # Now add all the columns
	    print STDERR ucfirst $name . " table schema is incorrect, adding " 
		. @columns_to_create . " missing column" 
		. ((@columns_to_create > 1)? "s." : ".");
	    my $alter_sql .= "ALTER TABLE $name ADD (" . (join ", ", @columns_to_create) . ");";
            
	    # Run the creation script.
	    if ($run) {
		$database->do($alter_sql) or die $database->errstr;
	    }
	}
    }

    return $database;
}

# iterate through each session and make sure that there is a
# corresponding user in the session table
sub check_sessions {
    my $session_driver = $globals->session_driver;
    my $session_args   = $globals->session_args;
    my $users_created = 0;
    local $database->{PrintError} = 0;
    my $do_session_check = sub {
	my $session = shift;
	my $session_id  = $session->id;
	my $source      = $session->param('.source') or return;
	my $config_hash = $session->param($source)   or return;
	if ($session_id eq 'c2f45ca6c2750c48cd2fd70b86ae43fb') {
	    warn "param gives ",$session->param('.uploadsid');
	    warn "page settings gives ",$config_hash->{page_settings}{uploadid};
	}
	my $uploadsid   = $session->param('.uploadsid') ||
	                  $config_hash->{page_settings}{uploadid};
	$uploadsid or return;

	my $sql         = "SELECT count(*) FROM session WHERE sessionid=? AND uploadsid=?";
	my $rows        = $database->selectrow_array($sql,undef,$session_id,$uploadsid);
	return if $rows > 0;
	warn "set sessionid=$session_id, uploadsid=$uploadsid. Rows = $rows";

	$sql       = 'UPDATE session SET uploadsid=? WHERE sessionid=?';
	$rows      = $database->do($sql,undef,$uploadsid,$session_id);
	return if $rows > 0;
	$database->do('insert INTO session (sessionid,uploadsid) VALUES(?,?)',
		      undef,$session_id,$uploadsid)
	    && $users_created++;
    };
    CGI::Session->find($session_driver,$do_session_check,$session_args);
    if ($users_created) {
	print STDERR "Added $users_created anonymous users to session table.\n";
    }
}


# Check Uploads IDs () - Makes sure every user ID has an uploads ID corresponding to it.
sub check_uploads_ids {
    print STDERR "Checking uploads IDs in database...";
    my $ids_in_db = $database->selectcol_arrayref("SELECT userid, uploadsid FROM session", { Columns=>[1,2] });
    my $missing = 0;
    if ($ids_in_db) {
	my %uploads_ids = @$ids_in_db;
	foreach my $userid (keys %uploads_ids) {
	    unless ($uploads_ids{$userid}) {
		print STDERR "missing uploads ID found.\n" unless $missing;
		print STDERR "- Uploads ID not found for $userid, ";                
		my $session = $globals->session($userid);
		my $settings= $session->page_settings;
		my $uploadsid = $session->param('.uploadsid') ||
		    $settings->{uploadid};
		$database->do("UPDATE session SET uploadsid = ? WHERE sessionid = ?", undef, $uploadsid, $userid) or print STDERR "could not add to database.\n" . DBI->errstr;
		print STDERR "added to database.\n" unless DBI->errstr;
		$missing = 1;
	    }
	}
    }
    print STDERR "all uploads IDs are present.\n" unless $missing;
}

# Check Data Sources () - Checks to make sure the data sources are there for each file.
sub check_data_sources {
    print STDERR "Checking for any files with missing data sources...";
    my $missing = 0;
    
    # Since we can't access the Database.pm access without the data source, we'll have to go in the back door,
    # and manually get the uploads ID, file path, and data source from the userdata folder.
    my $userdata_folder = $globals->user_dir;
    my @data_sources;
	opendir U, $userdata_folder;
	while (my $dir = readdir(U)) {
		next if $dir =~ /^\.+$/;
		next unless -d $dir;
		push @data_sources, $dir;
	}
	closedir(U);
	
	foreach my $data_source (@data_sources) {
	    # Within each data source, get a list of users with uploaded files.
	    my @users;
	    my $source_path = File::Spec->catfile($userdata_folder, $data_source);
	    opendir DS, $source_path;
	    while (my $folder = readdir(DS)) {
		    next if $folder =~ /^\.+$/;
		    next unless -d $folder;
		    my $user_path = File::Spec->catfile($userdata_folder, $data_source, $folder);
		    opendir USER, $user_path;
		    next unless readdir(USER);
		    push @users, $folder;
		    closedir(USER);
	    }
	    closedir(DS);
	    
	    foreach my $uploadsid (@users) {
	        # For each user, get the list of their files.
	        my @files;
            my $user_path = File::Spec->catfile($userdata_folder, $data_source, $uploadsid);
	        opendir FILE, $user_path;
	        while (my $file = readdir(FILE)) {
		        next if $file =~ /^\.+$/;
		        next unless -d $file;
		        push @files, $file;
	        }
	        closedir(FILE);
	        
	        # For each file, we have the data source and user - make sure the data source is present.
	        foreach my $file (@files) {
	            my @data_source_in_db = $database->selectrow_array("SELECT data_source FROM uploads WHERE path = ? AND userid = ?", undef, $file, $uploadsid);
	            unless (@data_source_in_db) {
	                print STDERR "missing source found.\n" unless $missing;
                    print STDERR "- Data Source not found for $file (owned by $uploadsid), ";                
                    $database->do("UPDATE uploads SET data_source = ? WHERE path = ? AND userid = ?", undef, $data_source, $file, $uploadsid) or print STDERR "could not add to database.\n" . DBI->errstr;
                    print STDERR "added to database.\n" unless DBI->errstr;
                    $missing = 1;
                }
	        }
	    }
	}
    print STDERR "all data sources are present.\n" unless $missing;
}

# Check All Files () - Checks the integrity of the file data for every user.
sub check_all_files {
    print STDERR "Checking for any files not in the database...";
    # Get all data sources
    my $userdata_folder = $globals->user_dir;
    my @data_sources;
    opendir U, $userdata_folder;
    while (my $dir = readdir(U)) {
	next if $dir =~ /^\.+$/;
	push @data_sources, $dir;
    }
    closedir(U);
	
    my $all_ok = 1;
    foreach my $data_source (@data_sources) {
	# Within each data source, get a list of users with uploaded files.
	my @uploads_ids;
	my $source_path = File::Spec->catfile($userdata_folder, $data_source);
	opendir DS, $source_path;
	while (my $folder = readdir(DS)) {
	    next if $folder =~ /^\.+$/;
	    my $user_path = File::Spec->catfile($userdata_folder, $data_source, $folder);
	    opendir USER, $user_path;
	    next unless readdir(USER);
	    push @uploads_ids, $folder;
	    closedir(USER);
	}
	closedir(DS);

        foreach my $uploadsid (@uploads_ids) {
	    my $userid  = check_uploadsid($source_path,$uploadsid) or next;
            my $this_ok = check_files($userid,$uploadsid, $data_source);
            $all_ok     = $this_ok if $all_ok;
        }
    }
    print STDERR "all files are accounted for.\n" if $all_ok;
}

# remove dangling upload directories
sub check_uploadsid {
    my ($source_path,$uploadsid) = @_;
    my ($userid)  = $database->selectrow_array('select (userid) from session where uploadsid=?',
					       undef,$uploadsid);
    unless ($userid) {
	print STDERR "Uploadsid $uploadsid has no corresponding user. Removing.\n";
	remove_tree(File::Spec->catfile($source_path,$uploadsid));
	return;
    }
    return $userid;
}

# Check Files (Uploads ID, Data Source) - Makes sure a user's files are in the database, add them if not.
sub check_files {
    my $userid      = shift or die "No user ID given, please check the gbrowse_metadb_config.pl script.\n";
    my $uploadsid   = shift or die "No uploads ID given, please check the gbrowse_metadb_config.pl script.\n";
    my $data_source = shift or die "No data source given, please check the gbrowse_metadb_config.pl script.\n";
    
    # Get the files from the database.
    my $files_in_db = $database->selectcol_arrayref("SELECT path FROM uploads WHERE userid=? AND data_source=?", 
						    undef, $userid, $data_source);
    my @files_in_db = @$files_in_db;
    
    # Get the files in the folder.
    my $path = $globals->user_dir($data_source, $uploadsid);
    my @files_in_folder;
    opendir D, $path;
    while (my $dir = readdir(D)) {
	next if $dir =~ /^\.+$/;
	push @files_in_folder, $dir;
    }
    closedir(D);
	
    my $all_ok = 1;
    foreach my $file (@files_in_folder) {
	my $found = grep(/$file/, @files_in_db);
	unless ($found) {
	    add_file($file, $userid, $uploadsid, $data_source,File::Spec->catfile($path,$file)) &&
		print STDERR "- File \"$file\" found in the \"$data_source/$uploadsid\" folder without metadata, added to database.\n";
	    $all_ok = 0;
	}
    }
    return $all_ok;
}

# Fix Permissions () - Grants the web user the required privileges on all databases.
sub fix_permissions {
    my (undef, $db_name) = $dsn =~ /.*:(database=)?([^;]+)/;
    $db_name ||= "gbrowse_login";
    
    if ($type =~ /mysql/i) {
	    my ($db_user) = $dsn =~ /user=([^;]+)/i;
	    my ($db_pass) = $dsn =~ /password=([^;]+)/i || ("");
	    $database->do("GRANT ALL PRIVILEGES on $db_name.* TO '$db_user'\@'%' IDENTIFIED BY '$db_pass' WITH GRANT OPTION") or die DBI->errstr;
    } elsif ($type =~ /sqlite/i) {
	    my ($path) = $dsn =~ /dbname=([^;]+)/i;
	    unless ($path) {
	        ($path) = $dsn =~ /DBI:SQLite:([^;]+)/i;
	    }
	    my $user  = GBrowse::ConfigData->config('wwwuser');
	    my $group = get_group_from_user($user);
	    
	    # Check if we need to, to avoid unnecessary printing/sudos.
	    unless ($user eq getpwuid((stat($path))[4])) {
	        unless ($group) {
	            print STDERR "Unable to look up group for $user. Will not change ownerships on $path.\n";
	            print STDERR "You should do this manually to give the Apache web server read/write access to $path.\n";
	        } else {
	            print STDERR "Using sudo to set ownership to $user:$group. You may be prompted for your login password now.\n";
	            die "Couldn't figure out location of database index from $dsn" unless $path;
	            system "sudo chown $user $path";
	            system "sudo chgrp $group $path";
	            system "sudo chmod a+x $path";
	        }
	    }
    }
}

# Create Database() - Creates the database specified (or the default gbrowse_login database).
sub create_database {
    my (undef, $db_name) = $dsn =~ /.*:(database=)?([^;]+)/;
    $db_name ||= "gbrowse_login";
    unless (DBI->connect($dsn)) {
        if ($dsn =~ /mysql/i) {
            print STDERR "Could not find $db_name database, creating...\n";
            
            my ($admin_user, $admin_pass);
            if ($admin) {
                ($admin_user) = $admin =~ /^(.*):/;
                ($admin_pass) = $admin =~ /:(.*)$/;
            }
            
            $admin_user ||= prompt("Please enter the MySQL administrator user", "root");
            $admin_pass ||= prompt("Please enter the MySQL administrator password", "");
            my $test_dbi = DBI->connect("DBI:mysql:database=mysql;user=$admin_user;password=$admin_pass;");
            $test_dbi->do("CREATE DATABASE IF NOT EXISTS $db_name");
            
            print STDERR "Database has been created!\n" unless DBI->errstr;
        }
    }
    # SQLite will create the file/database upon first connection.
}

# Add File (Full Path, Owner's Uploads ID, Data Source) - Adds $file to the database under a specified owner.
# Database.pm's add_file() is dependant too many outside variables, not enough time to re-structure.
sub add_file {    
    my $filename    = shift;
    my $userid      = shift;
    my $uploadsid   = shift;
    my $data_source = shift;
    my $full_path   = shift;

    my $imported = ($filename =~ /^(ftp|http|das)_/)? 1 : 0;
    my $description = "";
    my $shared = "private";

    my $trackid = md5_hex($uploadsid.$filename.$data_source);
    my $now = nowfun();
    $database->do("INSERT INTO uploads (trackid, userid, path, description, imported, creation_date, modification_date, sharing_policy, data_source) VALUES (?, ?, ?, ?, ?, $now, $now, ?, ?)", undef, $trackid, $userid, $filename, $description, $imported, $shared, $data_source);
    return $trackid;
}

# Now Function - return the database-dependent function for determining current date & time
sub nowfun {
    return ($type =~ /sqlite/i)? "datetime('now','localtime')" : 'NOW()';
}

# Escape Enums (type string) - If the string contains an ENUM, returns a compatible data type that works with SQLite.
sub escape_enums {
    my $string = shift;
    # SQLite doesn't support ENUMs, so convert to a varchar.
    if ($string =~ /^ENUM\(/i) {
        #Check for any suffixes - "NOT NULL" or whatever.
        my @options = ($string =~ m/^ENUM\('(.*)'\)/i);
        my @suffix = ($string =~ m/([^\)]+)$/);
        my @values = split /',\w*'/, $options[0];
        my $length = List::Util::max(map length $_, @values);
        $string = "varchar($length)" . $suffix[0];
    }
    return $string;
}

# Asks q question and sets a default - blatantly stolen (& modified) from Module::Build.
sub prompt {
  my $mess = shift
    or die "prompt() called without a prompt message";

  # use a list to distinguish a default of undef() from no default
  my @def;
  @def = (shift) if @_;
  # use dispdef for output
  my @dispdef = scalar(@def) ?
    ('[', (defined($def[0]) ? $def[0] : ''), '] ') :
    (' ', '');
    
  print STDERR "$mess ", @dispdef;

  my $ans = <STDIN>;
  chomp $ans if defined $ans;

  if ( !defined($ans)        # Ctrl-D or unattended
       or !length($ans) ) {  # User hit return
    print STDERR "$dispdef[1]\n";
    $ans = scalar(@def) ? $def[0] : '';
  }

  return $ans;
}

sub get_group_from_user {
    my $user = shift;
    my (undef,undef,undef,$gid) = getpwnam($user) or return;
    my $group = getgrgid($gid);
    return $group;
}

sub upgrade_schema {
    my $new_version   = shift;
    my ($old_version) = $database->selectrow_array('SELECT schema_version FROM dbinfo LIMIT 1');
    unless ($old_version) {
	# table is missing, so add it
	check_table('dbinfo',$dbinfo_columns);
	$old_version = 0;
    }
    backup_database();
    for (my $i=$old_version;$i<$new_version;$i++) {
	my $function = "upgrade_from_${i}_to_".($i+1);
	eval "$function();1" or die "Can't upgrade from version $i to version ",$i+1;
    }
}

sub backup_database {
    if ($type =~ /sqlite/i) {
	my ($src) = $dsn =~ /dbname=([^;]+)/i;
	unless ($src) {
	    ($src) = $dsn =~ /DBI:SQLite:([^;]+)/i;
	}
	my $time = localtime;
	my $dest = strftime("${src}_%d%b%Y.%H:%M",localtime);
	warn "backing up existing users database to $dest";
	system ('cp',$src,$dest);
    } elsif ($type =~ /mysql/i) {
	my $dest = strftime('gbrowse_users_%d%b%Y.%H:%M',localtime);
	warn "backing up existing users databse to ./$dest";
	my ($src) = $dsn =~ /dbname=([^;]+)/i;
	unless ($src) {
	    ($src) = $dsn =~ /DBI:mysql:([^;]+)/i;
	}
	my ($db_user) = $dsn =~ /user=([^;]+)/i;
	my ($db_pass) = $dsn =~ /password=([^;]+)/i || ("");
	no warnings;
	open SAVEOUT,">&STDOUT";
	open STDOUT,">$dest" or die "$dest: $!";
	system('mysqldump',"--user=$db_user","--password=$db_pass",$src);
	open STDOUT,">&SAVEOUT";
    } else {
	die "Don't know how to backup this driver";
    }
}

sub set_schema_version {
    my ($table,$version) = @_;
    $database->do("replace into $table (schema_version) values ($version)");
}

############################## one function to upgrade each level
sub upgrade_from_0_to_1 {

    # create dbinfo table
    check_table("dbinfo",           $dbinfo_columns);

    local $database->{AutoCommit} = 0;
    local $database->{RaiseError} = 1;
    eval {
	# this upgrades the original users table to the last version
	# before the session table was added
	check_table('users',$old_users_columns);

	# this creates the new session table
	check_table("session",  $session_columns);
	check_table("users_new",        $users_columns);

	# query to pull old data out of original users table
	my $select = $database->prepare(<<END) or die $database->errstr;
SELECT userid,uploadsid,username,email,pass,remember,openid_only,
       confirmed,cnfrm_code,last_login,created
FROM   users
END
    ;
	
	# query to insert data into new session table
	my $insert_session = $database->prepare(<<END) or die $database->errstr;
REPLACE INTO session (username,sessionid,uploadsid)
        VALUES (?,?,?)
END
    ;

	# query to insert data into new users table
	my $insert_user = $database->prepare(<<END) or die $database->errstr;
REPLACE INTO users_new (userid,      email,      pass,       remember, 
		        openid_only, confirmed, cnfrm_code, last_login, created)
        VALUES (?,?,?,?,?,?,?,?,?)
END
;
	$select->execute() or die $database->errstr;
	my %uploadsid_to_userid;

	while (my ($sessionid,$uploadsid,$username,@rest) = $select->fetchrow_array()) {
	    $insert_session->execute($username,$sessionid,$uploadsid)
		or die $database->errstr;
	    my $userid = $database->last_insert_id('','','','') or die "Didn't get an autoincrement ID!";
	    $insert_user->execute($userid,@rest) or die $database->errstr;
	    $uploadsid_to_userid{$uploadsid}=$userid;
	}
	$select->finish;
	$insert_session->finish;
	$insert_user->finish;
	# rename the current users table
	$database->do('drop table users')
	    or die "Couldn't drop old users table";
	$database->do('alter table users_new rename to users')
	    or die "Couldn't rename new users table";
	$database->do('create index index_session on session(username)')
	    or die "Couldn't index sessions table";

	# now do the uploads table
	# this upgrades to latest version 0
	check_table('uploads',      $old_uploads_columns);
	check_table("uploads_new",  $uploads_columns);

	$select = $database->prepare(<<END) or die $database->errstr;
SELECT uploadid,userid,path,title,description,imported,
       creation_date,modification_date,sharing_policy,users,
       public_users,public_count,data_source
FROM   uploads
END
    ;
	my $insert = $database->prepare(<<END) or die $database->errstr;
REPLACE INTO uploads_new (trackid,userid,path,title,description,imported,
			 creation_date,modification_date,sharing_policy,users,
			 public_users,public_count,data_source)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
END
    ;

	while (my ($trackid,$uploadsid,@rest) = $select->fetchrow_array()) {
	    my $uid = $uploadsid_to_userid{$uploadsid};
	    unless ($uid) {
		print STDERR "Found an upload from uploadsid=$uploadsid, but there is no corresponding user. Skipping...\n";
		next;
	    }
	    $insert->execute($trackid,$uid,@rest)
		or die $database->errstr;
	}
	$select->finish();
	$insert->finish();

	$database->do('drop table uploads')
	    or die "Couldn't drop old uploads table";
	$database->do('alter table uploads_new rename to uploads')
	    or die "Couldn't rename new uploads table";

	$database->commit();
    };
    if ($@) {
	warn "upgrade failed due to $@. Rolling back";
	eval {$database->rollback()};
	die "Can't continue";
    } else {
	print STDERR "Successfully upgraded schema from 0 to 1.\n";
	set_schema_version('dbinfo',1);
    }
}

__END__