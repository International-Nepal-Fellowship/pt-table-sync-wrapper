#!/usr/bin/perl

#Autor: Artur Neumann INF/N ict.projects@nepal.inf.org
#Version: see $version variable
#last change: 2013.12.2
#This script is written to syncronize the INF personnel database on different server
#Its written arround pt-table-sync: http://www.percona.com/doc/percona-toolkit
#and unison: http://www.cis.upenn.edu/~bcpierce/unison/
#This script can handle as much servers as you like and can eather sync one or two-way
#the server with this script running acts as hub and the other servers as spokes
#for two way sync of more than 2 server the hub sync all server the first time and then goes
#around a second time so the changes from the later sync servers also arrive on the earlier sync servers
#Conflicts (changes between two sync on different servers) will be recognized with the help of the "changelog" table
#In a conflict the later change wins but both parties gets an email with the information about the conflict.

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#To use this script please check the next lines and adjust them
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# PERL MODULE, make sure all modules are installed
use Data::Dumper;
use DBI;
use strict;
use warnings;
use IPC::Open3;
use POSIX qw/strftime/;
use POSIX qw/tmpnam/;

use MIME::Lite;    # to intall on ubuntu run 'sudo apt-get install libmime-lite-perl'
use Symbol qw(gensym);
use IO::File;
use Storable qw(dclone);

use Authen::SASL;    # to intall on ubuntu run 'sudo apt-get install libauthen-sasl-perl'
use MIME::Base64;

#Variables to configure
#------------------------------------------------------
my $version = "2.4.1";
my $ptTableSync = "/usr/bin/pt-table-sync";    #install from http://www.percona.com/doc/percona-toolkit/2.1/installation.html
my $syncCommandAdditionalAttributes = " --print --execute --conflict-comparison newest --verbose --conflict-error die --function MD5";
my $emailFromAddress                = 'yourmail@company.org';
my $unison                   = "/usr/bin/unison";               #to install on ubunto run 'sudo apt-get install unison'
my $conflictEmailCCAddresses = 'yourmail@company.org';    #separate addresses by comma
my $administratorAddresses   = 'yourmail@company.org';    #addresses the output of the script will be send
my $preExecutionSQLcommand  = "UPDATE `site` SET `maintenance` = '1' WHERE `site_specific_id` =?;";
my $postExecutionSQLcommand = "UPDATE `site` SET `maintenance` = '0' WHERE `site_specific_id` =?;";
my $mysql_connect_timeout=5;
my $mysql_read_timeout=1;


#use this line send emails via sendmail
#MIME::Lite->send('sendmail');

#use this line to send emails direct via SMTP
#if you use this you also need to enable the two lines above:
#use Authen::SASL; and #use MIME::Base64;

MIME::Lite->send( 'smtp', "company.org", AuthUser => 'mail@company.org', AuthPass => 'xxxx' );

#list of servers in the network
my %servers = (
        
        1 => { #this number must be the same id as in the auto_increment_offset variable in the my.cnf config file
               #AND the site_specific_id  in the site table

	           #this must be the server this script runs on, its the main one
	           host     => "localhost",
	           database => "dbname",
         	   username => "db-sync-user",
                   password => "db-syncpasword",
	           type     => "master",                  #the first server must be a master, it writes data to other servers
	           pathOfFilesToSync => "/var/www/fileUploads/"    #absolute path of the files that have to be synced.
        },
         2 => {
	           host     => "192.168.56.102",
	           database => "dbname",
         	   username => "db-sync-user",
                   password => "db-syncpasword",
	           type     => "master",                  #can be "master" OR "slave"
	                                                  #a master server will write his data to all other servers
	                                                  #so between master servers datachanges will be sync bidirectional
	                                                  #a slave server is not allowed to write data to other servers,
	                                                  #a slave server will just receive data and all changes on a slave
	                                                  #server will be overwritten at the next sync by data from the master server(s)
	           pathOfFilesToSync => "/var/www/fileUploads/"    #absolute path of the files that have to be synced.

        },
         3 => {
	           host     => "192.168.56.103",
	           database => "dbname",
         	   username => "db-sync-user",
                   password => "db-syncpasword",
	           type     => "master",                   #can be "master" OR "slave"
	           pathOfFilesToSync => "/var/www/fileUploads/"    #absolute path of the files that have to be synced.
        },  

);

#list of tables you like to sync.
#every table needs a single-column primary key
#syntax: ["table-name" , "conflict-column-name"]
my @tableData = (
	[ "country",                  "timestamp" ],
	[ "leaving_reason",           "timestamp" ],
	[ "leave_type",               "timestamp" ],
	[ "grade",                    "timestamp" ],
	[ "illness",                  "timestamp" ],
	[ "programme",                "timestamp" ],
	[ "project",                  "timestamp" ],
	[ "section",                  "timestamp" ],
	[ "unit",                     "timestamp" ],
	[ "post",                     "timestamp" ],
	[ "address",                  "address_timestamp" ],
	[ "email",                    "email_timestamp" ],
	[ "phone",                    "phone_timestamp" ],
	[ "name",                     "name_timestamp" ]

);


#do not change anything below this line or your computer will explode, the sun will fade, the universe colaps and the world we
#know will end. So be carefull, You have been warned!
#-------------------------------------------------------------------------------------

my @conflicts;
my @errors;
my %servers_to_retry;
my %dbh;
my $insertCount     = 0;
my $updateCount     = 0;
my $syncSummary     = "Version: $version \nSync started at: " . strftime( '%d-%m-%Y %H:%M', localtime ) . "\n\n";
my $fileSyncSummary = "";
my $verboseOutput   = $syncSummary;
my $errorOutput     = "";
my $unisonLogFile   = "";
my $errorString;
my $fields_hash;
my $server_id;
my $emailSubjectPostfix = "";

#This are MySQL and percona table sync error that just lead to a warning and a retry, all other errors will cause a abbort
my $warning_errors = ".*?((Lost connection to MySQL server)|(Can\'t connect to MySQL server)|(MySQL server has gone away)|(Issuing rollback)).*?";


my $sql;
my $sth;
my %DBattr = (
			   PrintError => 1,
			   RaiseError => 0,
);

#check if pt-table-sync and unison exists
if ( !-e $unison ) {
	$fileSyncSummary =
	    "cannot find $unison, I will not sync the files.\n"
	  . "To sync files please install unison from http://www.cis.upenn.edu/~bcpierce/unison/ "
	  . "or adjust the \$unison variable in this script. "
	  . "Tipp: for Debian/Ubuntu simply run 'sudo apt-get install unison'\n\n";

	errorMessage( 'warning', $fileSyncSummary );
}
if ( !-e $ptTableSync ) {
	errorMessage(
				  'critical',
				  "cannot find $ptTableSync, please install the percona-toolkit from "
					. "http://www.percona.com/software/percona-toolkit or "
					. "adjust the \$ptTableSync variable in this script\n\n"
	);

}

#

#connect to every server
#and check if the table and conflict-column exist
foreach $server_id (sort (keys %servers)) {

	print "Connecting ... host: $servers{$server_id}{host}  database:$servers{$server_id}{database}  \n";
	my $db = DBI->connect( 'DBI:mysql:' . $servers{$server_id}{database} . ';host=' . $servers{$server_id}{host}.';mysql_connect_timeout=5;mysql_read_timeout=1',
					$servers{$server_id}{username},
					$servers{$server_id}{password} );
			
	$dbh{$server_id}=$db;	
	

	if ( defined $DBI::errstr ) {
		$errorString = "\nCould not connect to database on server $servers{$server_id}{host}\n $DBI::errstr\n";

		#if we have a problem with the first server (the main one and the one running this script), we cannot proceed
		if ( $server_id == 1 ) {
			errorMessage( 'critical', $errorString );
		}

		#if it not the main server, we just remove the server from the list and sync the rest
		else {
			errorMessage( 'warning', $errorString . "We will not sync this server and proceed with the next one (if any)\n\n" );
			$servers{$server_id}{type} = "delete";
			next;
		}
	}

	print "Cheking database structure ... \n";
	foreach my $table (@tableData) {

		$sql = "show columns from `@$table[0]`";
		$fields_hash = $dbh{$server_id}->selectall_hashref( $sql, "Field", \%DBattr );

		#check if table exists
		if ( defined $DBI::errstr ) {

			$errorString = "\nDatabase Error on server $servers{$server_id}{host}\n $DBI::errstr\n";

			#if we have a problem with the first server (the main one and the one running this script), we cannot proceed
			if ( $server_id == 1 ) {
				errorMessage( 'critical', $errorString );
			}

			#if it not the main server, we just remove the server from the list and sync the rest
			else {
				errorMessage( 'warning', $errorString . "We will not sync this server and proceed with the next one (if any)\n\n" );
				$servers{$server_id}{type} = "delete";
				last;
			}

		}
		else {

			#check if conflict-column exists and if it has the type "timestamp"
			if ( $fields_hash->{ @$table[1] }{'Type'} ne 'timestamp' ) {
				$errorString =
				    "The column "
				  . `@$table[1]`
				  . " does not exist in the table "
				  . `@$table[0]`
				  . " on the server "
				  . $servers{$server_id}{host}
				  . " or its not of type 'timestamp' - please doublecheck the \@tableData list and the database on the server\n"
				  . "We will not sync this server and proceed with the next one (if any)\n\n";

				errorMessage( 'warning', $errorString );
				$servers{$server_id}{type} = "delete";
				last;

			}
		}
	}
}

#run preexecution command on the hub
print "run preexecution command on server " . $servers{1}{host} . "\n";
$dbh{1}->do( $preExecutionSQLcommand, undef, 1 );

if ( defined $DBI::errstr ) {
	errorMessage( 'critical', " could not run preexecution command on " . $servers{1}{host} . "\n$DBI::errstr\n" );
}


#delete Servers with type==delete
deleteMarkedServers();

my $command;
my $count_master_servers = 0;
my $unisonLogFileFh;

#create a temp file as unison log file
do { $unisonLogFile = tmpnam() } until $unisonLogFileFh = IO::File->new( $unisonLogFile, O_RDWR | O_CREAT | O_EXCL );

# install atexit-style handler so that when we exit or die,
# we automatically delete this temporary file
END {
	if ( -e $unisonLogFile ) {
		unlink($unisonLogFile) or die "Couldn't delete unison log file: $unisonLogFile : $!";
	}
}

#syncing all the servers the first time
foreach $server_id (sort (keys %servers)) {
	if ( $server_id != 1 ) {
		syncServer( "first", $server_id );
		
		if (!exists $servers_to_retry{$server_id}) {
			#make a time stamp on the hub
			stampServer( 1, $server_id );

			#stamp every server with a stamp from a server it has already data from
			for ( my $i = 1 ; $i < $server_id ; $i++ ) {

				  if (!exists $servers_to_retry{$i} and exists $servers{$i}) {
				    stampServer( $server_id, $i );
				  }				
			}

		}		
		
	}
}


#retry syncing failed servers
my $print_string= "\nServers to retry:" . %servers_to_retry . "\n";
print $print_string;
$verboseOutput = $verboseOutput . $print_string;

foreach my $server_id (keys %servers_to_retry){
	syncServer( "firstretry", $server_id );
	
	if ($servers{$server_id}{type} ne 'delete')	{
		#make a time stamp on the hub
		stampServer( 1, $server_id );

		#stamp every server with a stamp from a server it has already data from
		for ( my $i = 1 ; $i < $server_id ; $i++ ) {

			   if (!exists $servers_to_retry{$i} and exists $servers{$i}) {
			    stampServer( $server_id, $i );
			  }				
		}
	}	
	
}

#delete all servers that could not be synced even after a retry
deleteMarkedServers();

#count the remaining master servers
$count_master_servers = scalar (grep { $servers{$_}{type} eq 'master' } (keys %servers));


#if we have more than 2 masters we need to sync again
#but also if there are just two masters and there are slaves between servers[0] and the second master
#these slaves have to be sync again to get the data from the second master
#there is also no need to sync again in there were no changes made at all
if (( $count_master_servers > 2 || ( $count_master_servers == 2 && $servers{2}{type} ne "master" )) 
	  && ($insertCount > 0 || $updateCount > 0) ) {

	%servers_to_retry=();
	
	#sync every server (exept the last one) again to distribute the changes from the later servers to the earlier ones
	foreach $server_id (sort (keys %servers)) {
		if ( $server_id != 1 ) {
			syncServer( "second", $server_id );
	
			if (!exists $servers_to_retry{$server_id})
			{
				#stamp every server with a stamp of the server it now got the data from
				#(sort (keys %servers))[-1] gets the highest key (id) in the hash				
				for ( my $i = (sort (keys %servers))[-1] ; $i > $server_id ; $i-- ) {
					if (exists $servers{$i}) {
						stampServer( $server_id, $i );
					}
				}
			}			
		}
	}	
	
	#retry syncing failed servers
	$print_string= "\nServers to retry:" . %servers_to_retry . "\n";
	print $print_string;
	$verboseOutput = $verboseOutput . $print_string;
	
	
	#retry the failed ones
	foreach my $server_id (keys %servers_to_retry){
		syncServer( "secondretry", $server_id );
		if ($servers{$server_id}{type} ne 'delete')
		{
			#stamp every server with a stamp of the server it now got the data from
			for ( my $i = (sort (keys %servers))[-1] ; $i > $server_id ; $i-- ) {
				if (exists $servers{$i}) {
					stampServer( $server_id, $i );
				}
			}
		}		
	}	

	#delete all servers that could not be synced even after a retry
	deleteMarkedServers();

} else {
	#if there were no need for a second sync we know that every server has all information, so we can stamp all rest servers
	foreach $server_id (sort (keys %servers)) {
		if ( $server_id != 1 ) {
			#stamp every server with a stamp of the server it now got the data from				
			for ( my $i = (sort (keys %servers))[-1] ; $i > $server_id ; $i-- ) {
				if (exists $servers{$i}) {
					stampServer( $server_id, $i );
				}
			}			
		}
	}	
}

#sending emails to loosers and winners
print "sending emails ...\n";
foreach my $conflict (@conflicts) {

	my $loosing_party_text      = '';
	my $loosing_party_addresses = '';

	for ( my $i = 0 ; $i < @{ $conflict->{'loosing_parties'} } ; $i++ ) {

		$loosing_party_text =
		    $loosing_party_text
		  . "==========="
		  . ( $i + 1 )
		  . "===========\n"
		  . $conflict->{'loosing_parties'}[$i]{'comment'}
		  . " - timestamp: "
		  . $conflict->{'loosing_parties'}[$i]{'timestamp'} . "\n"
		  . "made by "
		  . $conflict->{'loosing_parties'}[$i]{'person'}{'full_name'} . " - "
		  . "email: "
		  . $conflict->{'loosing_parties'}[$i]{'person'}{'email'}
		  . " username: "
		  . $conflict->{'loosing_parties'}[$i]{'person'}{'user_name'}
		  . " working on server: " . "\""
		  . $conflict->{'loosing_parties'}[$i]{'server'}{'host'}
		  . "\"\n\n";

		$loosing_party_addresses = $loosing_party_addresses . ',' . $conflict->{'loosing_parties'}[$i]{'person'}{'email'}

	}

	my $msg = MIME::Lite->new(
							   From    => $emailFromAddress,
							   To      => $conflict->{'winning_party'}{'person'}{'email'} . $loosing_party_addresses,
							   Cc      => $conflictEmailCCAddresses,
							   Subject => 'Conflict during sync of INF personnel database!',
							   Data    => "There was an error during the synchronization  of the INF personnel database.\n"
								 . "Several person modified the same record in the table "
								 . "\"$conflict->{'table'}\""
								 . " on different servers.\n"
								 . "To solve the conflict we kept the change of "
								 . $conflict->{'winning_party'}{'person'}{'full_name'} . " - "
								 . "email: "
								 . $conflict->{'winning_party'}{'person'}{'email'}
								 . " username: "
								 . $conflict->{'winning_party'}{'person'}{'user_name'}
								 . " working on server: " . "\""
								 . $conflict->{'winning_party'}{'server'}{'host'} . "\"\n"
								 . "details of the winning data:\n"
								 . $conflict->{'winning_party'}{'comment'}
								 . " - timestamp:"
								 . $conflict->{'winning_party'}{'timestamp'} . "\n\n"
								 . "there were "
								 . @{ $conflict->{'loosing_parties'} }
								 . " changes overwritten on other servers: \n"
								 . $loosing_party_text
								 . "Please contact the persons involved in this conflict and "
								 . "check which data is most actual / accurate!"
	);

	$msg->send;
}

$Data::Dumper::Terse = 0;
$Data::Dumper::Indent = 3;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Varname  = "conflict";
$verboseOutput          = Dumper(@conflicts) . "\n---------------------------------------\n\n" . $verboseOutput;

printErrorsAndSummary();
sendAdministratorEmail();

sub deleteMarkedServers {

	#delete all the servers with problems from the list
	foreach $server_id (sort (keys %servers)) {
		if ( $servers{$server_id}{type} eq "delete" ) {
			delete ($servers{$server_id});
			delete ($dbh{$server_id});		
			
		}	
	}

}

sub checkForConflicts {

	
	my $server_to_change->{'host'}	= $_[0];
	my $record_id     = $_[1];
	my $table_name    = $_[2];
	my $just_synced_server_id     = $_[3];
	my $server_id_with_most_recent_change;
	my $server_id_to_check_for_conflict;
	my $time_of_oldest_log->{'this_time'} = '0000-00-00';
	my $change_log;
	my $sync_log;
	my $changelog_sql;

	my $print_string= "Check for conflicts. record_id=$record_id Table: $table_name\n";
	print $print_string;
	$verboseOutput = $verboseOutput . "\n". $print_string;

	#before the UPDATE statement the pt-sync-table tools shows us the server that was updated
	#so the other one is the one with the most recent changes
	#As we always sync from $server[0], the server with the most recent data must be either $server[0] or
	#the one we are syncing just now.
	if ( $server_to_change->{'host'} eq $servers{1}{host} ) {
		$server_id_with_most_recent_change = $just_synced_server_id;
	}
	else {
		$server_id_with_most_recent_change = 1;
	}

	#TODO can we combine that with the IF statement before?
	foreach my $server_id_loop (sort (keys %servers)) {
		if ( $server_to_change->{'host'} eq $servers{$server_id_loop}{host} ) {
			$server_to_change->{'id'} = $server_id_loop;
			print "found server_to_change ID " . $server_to_change->{'id'}  . "\n";
			last;
		}

	}

	my %conflict;

	#first check the updated host if there were any conflicts after the last sync
	#a conflict is when there was an update on the same record since the last sync

	#we just need to check master-servers, because slaves will be overwritten anyway
	if ($servers{$server_to_change->{'id'}}{type} eq "master" )
	{				
		
		#The UNION in the Subquery makes sure  there is a date even if the server was never synced before
		$changelog_sql = 
				   "SELECT  `change_log`.`timestamp` ,
							`change_log`.comment,
							`users`.`email`,
							`users`.`name`,
							`users`.`lastname`,
							`users`.`user_name`
					FROM `change_log`
					JOIN `users` ON `change_log`.`user_id` = `users`.`id`
					WHERE `table` = '$table_name'
							AND `record_id` = '$record_id'
							AND `change_log`.`timestamp` > 
								(
								SELECT this_time FROM `sync` WHERE sync_from = ? 
								UNION SELECT '0000-00-00' 
								ORDER BY this_time DESC LIMIT 1
								)
							
					ORDER BY `change_log`.`timestamp` DESC
					LIMIT 1";

		my %loosing_party;

		#see if we have a entry in the change_log
		
						
		my $db = connectToMySQLServer ($server_to_change->{'id'});
		
		if (!$db) {
			errorMessage( 'warning', "could not check for conflicts on " . $server_to_change->{'host'} . "\n" );
			
		} else {
			$change_log = $db->selectrow_hashref( $changelog_sql, undef, $server_id_with_most_recent_change );
			if ( defined $DBI::errstr ) {
				if ($DBI::errstr =~ $warning_errors ) {
					errorMessage( 'warning', "could not check for conflicts on " . $server_to_change->{'host'} . "\n$DBI::errstr\n" );

				}
				#anything else will lead to an abbort
				else {
				   errorMessage( 'critical', "could not check for conflicts on " . $server_to_change->{'host'} . "\n$DBI::errstr\n" );

				}
			}
			
			$db->disconnect;
		}
		
		if ( defined $change_log ) {

			print "Found Conflict (changelog) ".$change_log->{'timestamp'} . "\n";
			 
			#now we discovered a real conflict (the same row in the same table is changed on least two servers between
			#the last sync and now)

			#we found a loosing party
			#for cheking who is winner and who is looser we trust pt-table-sync and NOT the timestamps in the
			#change_log table
			#pt-table-sync tould us already that it updated one of the servers, so we know for sure this one
			#is a looser.
			if ( not defined $change_log->{'name'} ) {
				$change_log->{'name'} = '';
			}
			if ( not defined $change_log->{'lastname'} ) {
				$change_log->{'lastname'} = '';
			}
			$loosing_party{'comment'}             = $change_log->{'comment'};
			$loosing_party{'person'}{'email'}     = $change_log->{'email'};
			$loosing_party{'person'}{'full_name'} = $change_log->{'name'} . " " . $change_log->{'lastname'};
			$loosing_party{'person'}{'user_name'} = $change_log->{'user_name'};
			$loosing_party{'timestamp'}           = $change_log->{'timestamp'};
			$loosing_party{'server'}{'host'}      = $server_to_change->{'host'};
			$loosing_party{'server'}{'id'}        = $server_to_change->{'id'};
			push( @{ $conflict{'loosing_parties'} }, {%loosing_party} );
			
			
			#get the data of the winning party
			my $db = connectToMySQLServer ($server_id_with_most_recent_change);
		
			if (!$db) {
				errorMessage( 'warning', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n" );
				
			} else {
				$change_log = $db->selectrow_hashref( $changelog_sql, undef, $server_to_change->{'id'} );
				if ( defined $DBI::errstr ) {
					if ($DBI::errstr =~ $warning_errors ) {
						errorMessage( 'warning', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n" );

					}
					#anything else will lead to an abbort
					else {
					   errorMessage( 'critical', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n$DBI::errstr\n" );

					}
				}
				
				$db->disconnect;
			}
			
			#If that is not set then we cannot find the winning party yet, will will find it later by checking the synclog
			if ( defined $change_log ) {
				$conflict{'winning_party'}{'comment'}             = $change_log->{'comment'};
				$conflict{'winning_party'}{'person'}{'email'}     = $change_log->{'email'};
				$conflict{'winning_party'}{'person'}{'full_name'} = $change_log->{'name'} . " " . $change_log->{'lastname'};
				$conflict{'winning_party'}{'person'}{'user_name'} = $change_log->{'user_name'};
				$conflict{'winning_party'}{'timestamp'}           = $change_log->{'timestamp'};
				$conflict{'winning_party'}{'server'}{'host'}      = $servers{$server_id_with_most_recent_change}{host};
				$conflict{'winning_party'}{'server'}{'id'}        = $server_id_with_most_recent_change;
			}
		}
	}

	#check for conflicts in the past sync log

	#print "Checking for conflicts on other servers\n";
	foreach $server_id_to_check_for_conflict (sort (keys %servers)) {
	
		#we just need to check master-servers, because slaves will be overwritten anyway
		#and the server that has the most recent change don't need to be checked
		if (    $server_id_to_check_for_conflict != $server_id_with_most_recent_change
			 && $server_id_to_check_for_conflict != $server_to_change->{'id'}
			 && $servers{$server_id_to_check_for_conflict}{type} eq "master" )
		{
			
			print "checking for conflicts sync_log : " . $server_id_to_check_for_conflict  . "\n";
			print " server_id_with_most_recent_change " . $server_id_with_most_recent_change . "\n";
			print " server_to_change->{'id'} " . $server_to_change->{'id'} . "\n";
			
			#The UNION in the Subquery makes sure  there is a date even if the server was never synced before
			$sql = "SELECT  `comment`,
							`timestamp`,
							`user_name`,
							`user_email`,
							`user_firstname`,
							`user_lastname`,
							`time_of_change_on_remote_server`
						FROM `sync_log`

						WHERE `table` = ?
								AND `record_id` = ?
								AND `site_id_from` = ?
								AND `site_id_to` = 1
								AND `time_of_change_on_remote_server` > 
									(
									SELECT this_time FROM `sync` WHERE sync_from = ? 
									AND sync_to = ?
									UNION SELECT '0000-00-00' 
									ORDER BY this_time DESC LIMIT 1
									)
						ORDER BY `timestamp` DESC
						LIMIT 1";

			my %loosing_party;

			#print $sql ."\n";
			#print $table_name . " " .
			#										$record_id. " " .
			#										$server_id_to_check_for_conflict . " " .
			#										
			#										$server_id_with_most_recent_change. " " . 
			#										$server_id_to_check_for_conflict . "\n";
			#
			$sync_log = $dbh{1}->selectrow_hashref( $sql, undef, 
													$table_name,
													$record_id,
													$server_id_to_check_for_conflict , 
													$just_synced_server_id, 
													$server_id_to_check_for_conflict);
			if ( defined $DBI::errstr ) {
			   errorMessage( 'critical', "could not check for conflicts for " . $servers{$server_id_to_check_for_conflict}{host} . "\n$DBI::errstr\n" );
			}
			
		
			if ( defined $sync_log ) {
				
				print "Found Conflict (synclog) ".$sync_log->{'timestamp'} . "\n";
				
				
				if ( not defined $sync_log->{'name'} ) {
					$sync_log->{'name'} = '';
				}
				if ( not defined $sync_log->{'lastname'} ) {
					$sync_log->{'lastname'} = '';
				}

				
				#if we overwrite the HUB, the server we just checked must be a looser otherwise the winner
				if ($server_to_change->{'id'} == 1) {
					$loosing_party{'comment'}             = $sync_log->{'comment'};
					$loosing_party{'person'}{'email'}     = $sync_log->{'user_email'};
					$loosing_party{'person'}{'full_name'} = $sync_log->{'user_firstname'} . " " . $sync_log->{'user_lastname'};
					$loosing_party{'person'}{'user_name'} = $sync_log->{'user_name'};
					$loosing_party{'timestamp'}           = $sync_log->{'time_of_change_on_remote_server'};
					$loosing_party{'server'}{'host'}      = $servers{$server_id_to_check_for_conflict}{host};
					$loosing_party{'server'}{'id'}        = $server_id_to_check_for_conflict;
					push( @{ $conflict{'loosing_parties'} }, {%loosing_party} );
					
					
					#get the data of the winning party
					my $db = connectToMySQLServer ($server_id_with_most_recent_change);
				
					if (!$db) {
						errorMessage( 'warning', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n" );
						
					} else {
						$change_log = $db->selectrow_hashref( $changelog_sql, undef, $server_to_change->{'id'} );
						if ( defined $DBI::errstr ) {
							if ($DBI::errstr =~ $warning_errors ) {
								errorMessage( 'warning', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n" );
		
							}
							#anything else will lead to an abbort
							else {
							   errorMessage( 'critical', "could not get winning party informations from " . $servers{$server_id_with_most_recent_change}{host} . "\n$DBI::errstr\n" );
		
							}
						}
						
						$db->disconnect;
					}
					
					$conflict{'winning_party'}{'comment'}             = $change_log->{'comment'};
					$conflict{'winning_party'}{'person'}{'email'}     = $change_log->{'email'};
					$conflict{'winning_party'}{'person'}{'full_name'} = $change_log->{'name'} . " " . $change_log->{'lastname'};
					$conflict{'winning_party'}{'person'}{'user_name'} = $change_log->{'user_name'};
					$conflict{'winning_party'}{'timestamp'}           = $change_log->{'timestamp'};
					$conflict{'winning_party'}{'server'}{'host'}      = $servers{$server_id_with_most_recent_change}{host};
					$conflict{'winning_party'}{'server'}{'id'}        = $server_id_with_most_recent_change;

							
					
					
					
					

				}
				else {
					$conflict{'winning_party'}{'comment'}             = $sync_log->{'comment'};
					$conflict{'winning_party'}{'person'}{'email'}     = $sync_log->{'user_email'};
					$conflict{'winning_party'}{'timestamp'}           = $sync_log->{'time_of_change_on_remote_server'};
					$conflict{'winning_party'}{'person'}{'full_name'} = $sync_log->{'user_firstname'} . " " . $sync_log->{'user_lastname'};
					$conflict{'winning_party'}{'person'}{'user_name'} = $sync_log->{'user_name'};					
					$conflict{'winning_party'}{'server'}{'host'}      = $servers{$server_id_to_check_for_conflict}{host};
					$conflict{'winning_party'}{'server'}{'id'}        = $server_id_to_check_for_conflict;								
				}
				
			}
		}
	}
	
	#print Dumper($conflict{'loosing_parties'});
	
	if ( defined $conflict{'loosing_parties'} && @{ $conflict{'loosing_parties'} } ) {		

		#check if there is a conflict with this table and record_id
		#if yes we will have to see who is the real winner
			
		my $conflicts_exists = 0;
		my $conflict_num = 0;
		foreach my $conflict_loop (@conflicts) {
			if (    $conflict_loop->{'table'} eq $table_name
				 && $conflict_loop->{'record_id'} eq $record_id)
			{
				$conflicts[$conflict_num]{'winning_party'}=$conflict{'winning_party'};
				
				#collect all loosing parties
				for ( my $i = 0 ; $i < @{ $conflict_loop->{'loosing_parties'} } ; $i++ ) {
					
					if (!grep {
  							$_->{server}{id} == $conflict_loop->{'loosing_parties'}[$i]{server}{id}
							} @{ $conflict{'loosing_parties'} })
								{
									push( @{ $conflict{'loosing_parties'} }, $conflict_loop->{'loosing_parties'}[$i] );	
								}
					
					
		  
					}
	
				$conflicts[$conflict_num]{'loosing_parties'}=$conflict{'loosing_parties'};
				$conflicts_exists=1;
				last;
	
			}
			$conflict_num++;
		
		}
		
		if ($conflicts_exists == 0) {
			$conflict{'table'} = $table_name;
			$conflict{'record_id'} = $record_id;
			#print "pushing conflict to conflicts";
			push @conflicts, {%conflict};	
			}
	}
	
}

sub syncServer {
	my $runIdentifier   = $_[0]; #can be: "first,second,firstretry,secondretry"
	my $server_id = $_[1];
	my $stopSyncingThisServer = 0; #will be set to 1 in case of a "retry" error
	my $print_string;
	my $server_id_to_check_for_conflict;


#running the preexecution command on the server
	print "run preexecution command on server " . $servers{$server_id}{host} . "\n";
	my $db = connectToMySQLServer ($server_id);
	
	if (!$db) {

			if ($runIdentifier eq 'firstretry' or $runIdentifier eq 'secondretry') {
				errorMessage( 'warning', "could not run preexecution command on " . $servers{$server_id}{host} . "\nWe will not sync the server " .$servers{$server_id}{host} . " and proceed with the next one (if any)\n\n" );
				$servers{$server_id}{type} = "delete";
			}	else {
				errorMessage( 'retry', "could not run preexecution command on " . $servers{$server_id}{host} . "\n", $server_id );				
			}	
		
			$stopSyncingThisServer = 1;
	} else {
	
		$db->do( $postExecutionSQLcommand, undef, $server_id );
	
		if ( defined $DBI::errstr ) {
			if ($runIdentifier eq 'firstretry' or $runIdentifier eq 'secondretry') {
				errorMessage( 'warning', "could not run preexecution command on " . $servers{$server_id}{host} . "\n$DBI::errstr\nWe will not sync the server " .$servers{$server_id}{host} . " and proceed with the next one (if any)\n\n" );
				$servers{$server_id}{type} = "delete";
			}	else {
				errorMessage( 'retry', "could not run preexecution command on " . $servers{$server_id}{host} . "\n$DBI::errstr\n", $server_id );
			}			
			
			$stopSyncingThisServer = 1;
		}
	
	$db->disconnect;
	}



	foreach my $table (@tableData) {
		
		#don't try to sync the other tables of this server or if there was a problem before don't even start
		if ($stopSyncingThisServer == 1) {
			last;
		}
		
		$command = "$ptTableSync ";

		#for the second run we don't need bidirectional syncinng as we just destributing the canges from the later sync servers.
		if ( $servers{$server_id}{type} eq 'master'  and ($runIdentifier eq "first" or $runIdentifier eq "firstretry")) {
			$command = $command . " --bidirectional ";
		}
		$command =
		    $command
		  . "h=$servers{1}{host},D=$servers{1}{database},t=@$table[0],u=$servers{1}{username},p=$servers{1}{password} "
		  . "h=$servers{$server_id}{host},D=$servers{$server_id}{database},u=$servers{1}{username},p=$servers{$server_id}{password} "
		  . " --conflict-column @$table[1] --ignore-columns @$table[1] $syncCommandAdditionalAttributes";
		
		if ( $runIdentifier eq 'firstretry' or  $runIdentifier eq 'secondretry' ) {
			print "retry ";
			$verboseOutput = $verboseOutput . "retry ";
		}

		print "syncing ";
		$verboseOutput = $verboseOutput . "syncing ";

		if (  $runIdentifier eq 'second' or  $runIdentifier eq 'secondretry' ) {
			print "second time ";
			$verboseOutput = $verboseOutput . "second time ";
		}
		

		$print_string = " server: $servers{$server_id}{host} -  table : '@$table[0]' - conflict column: '@$table[1]'\n";
		print $print_string;
		$verboseOutput = $verboseOutput . $print_string;

		#stuff for catching STDERR and STDOUT see: http://learn.perl.org/faq/perlfaq8.html#How-can-I-capture-STDERR-from-an-external-command-
		#the output contains the count of INSERT / UPDATES and the complete SQL statement
		#we run throw all the output lines and see if we find an UPDATE, if yes we have to check if this item was also changed on an other serve
		local *CATCHERR = IO::File->new_tmpfile;
		my $pid = open3( gensym, \*CATCHOUT, ">&CATCHERR", $command );
		while (<CATCHOUT>) {

			$verboseOutput = $verboseOutput . "$_";

			#count the inserts and updatess
			if ( $_ =~ /(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/ ) {			

				if ( $1 > 0 or $2 > 0 ) {
					$errorString =
					   "There should not be any REPLACE or DELETE statements whily syncing. "
					  . "Please make sure the databasese are 100% identical before the first sync. \n"
					  . "See also the last SQL statement in the verbose information file \n";
					errorMessage( 'critical', $errorString );
				}
			}

			#found a UPDATE statment!
			my $sql_statement = $_;
			my $first_server_id = 1;
			if ($sql_statement =~ /\/\*(.*)\*\/ UPDATE `($servers{$first_server_id}{database}|$servers{$server_id}{database})`.`@$table[0]`.*WHERE `id`=\'(\d+)\' LIMIT 1\;/ ) 
			{
				
				$updateCount = $updateCount + 1;
				#before the UPDATE statement the pt-sync-table tools shows us the server that was updated this is $1
				my $server_to_change = $1;
				my $record_id = $3;
				
				wrileSyncLog('UPDATE',$server_id,$server_to_change,@$table[0],$record_id,$sql_statement);
			
				#in the first round of syncing we have to check for conflicts. But we don't need the conflict checks in the second
				#round of syncing, because all conflict information should be there after the first round.
				if ($runIdentifier eq "first" or $runIdentifier eq "firstretry")
				{
					

					#TODO erklären was hier passiert
					$server_id_to_check_for_conflict = grep { $servers{$_}{host} eq $server_to_change } keys %servers;

					#we just need to check for conflicts if the server we just updated was a master server
					#slaves will be overwritten anyway					
					if ( $servers{$server_id_to_check_for_conflict}{type} eq 'master' ) {
						#TODO we could use $server_id_to_check_for_conflict and replace $server_to_change here
						checkForConflicts( $server_to_change, $record_id, @$table[0], $server_id );
					}
				}
				
			} 
			#this case hapends for the one way syncs
			elsif ($sql_statement =~ /UPDATE `($servers{$first_server_id}{database}|$servers{$server_id}{database})`.`@$table[0]`.*WHERE `id`=\'(\d+)\' LIMIT 1\s+\/\*percona-toolkit src_db:($servers{$first_server_id}{database}|$servers{$server_id}{database}) src_tbl:@$table[0] src_dsn:D=($servers{$first_server_id}{database}|$servers{$server_id}{database}),h=(.*),p=...,t=@$table[0],.* dst_db:($servers{$first_server_id}{database}|$servers{$server_id}{database}) dst_tbl:@$table[0] dst_dsn:D=.*,h=(.*),p=.*/) {
				$updateCount = $updateCount + 1;
				my $server_to_change = $7;	
				my $record_id = $2;			
				wrileSyncLog('UPDATE',$server_id,$server_to_change,@$table[0],$record_id,$sql_statement);				
				
			} 
			elsif ($sql_statement =~ /\/\*(.*)\*\/ INSERT INTO `($servers{$first_server_id}{database}|$servers{$server_id}{database})`.`@$table[0]`.* VALUES \('(\d+)',.*\)\;/) {

				$insertCount = $insertCount + 1;
				
				#before the INSERT statement the pt-sync-table tools shows us the server that was updated this is $1
				my $server_to_change = $1;	
				my $record_id = $3;			
				wrileSyncLog('INSERT',$server_id,$server_to_change,@$table[0],$record_id,$sql_statement);
			} 
			elsif ($sql_statement =~ /INSERT INTO `($servers{$first_server_id}{database}|$servers{$server_id}{database})`.`@$table[0]`.* VALUES \('(\d+)',.*\)\s+\/\*percona-toolkit src_db:($servers{$first_server_id}{database}|$servers{$server_id}{database}) src_tbl:@$table[0] src_dsn:D=($servers{$first_server_id}{database}|$servers{$server_id}{database}),h=(.*),p=...,t=@$table[0],.* dst_db:($servers{$first_server_id}{database}|$servers{$server_id}{database}) dst_tbl:@$table[0] dst_dsn:D=.*,h=(.*),p=.*/) {

				$insertCount = $insertCount + 1;

				my $server_to_change = $7;	
				my $record_id = $2;			
				wrileSyncLog('INSERT',$server_id,$server_to_change,@$table[0],$record_id,$sql_statement);				
			}
		}

		waitpid( $pid, 0 );
		seek CATCHERR, 0, 0;

		#if there was an error during the sync check the severity
		while (<CATCHERR>) {
				#when this errors occure we will try it again
				if ($_ =~ $warning_errors ) {
					
					$stopSyncingThisServer=1;
					#if its already the retry run then mark the server as to be deleted and give a warning
					if ($runIdentifier eq 'firstretry' or $runIdentifier eq 'secondretry') {
						errorMessage( 'warning', $_ . "\nWe will not sync the server " .$servers{$server_id}{host} . " and proceed with the next one (if any)\n\n" );
						$servers{$server_id}{type} = "delete";
					}
					
					#if the error comes the first time we will retry to sync the server later
					else {
						errorMessage( 'retry',  $_, $server_id);
						
						}
				}
				#anything else will lead to an abbort
				else {
				   errorMessage( 'critical', $_ );
				}
				 
				
			
		}

		$verboseOutput = $verboseOutput . "------------------------\n\n";
		
		#don't try to sync the other tables of this server
		if ($stopSyncingThisServer == 1) {
			last;
		}

	}


	#some last steps of the sync, but we don't try them if the sync was aborted during the database sync
	if ($stopSyncingThisServer == 0) {

		#sync the files
		print "Syncing files with $servers{$server_id}{host}\n";
	
		$command =
		    "$unison -silent  -logfile $unisonLogFile -ui text -batch "
		  . " -nodeletion $servers{1}{pathOfFilesToSync}  -nodeletion ssh://$servers{$server_id}{host}/$servers{$server_id}{pathOfFilesToSync}"
		  . " $servers{1}{pathOfFilesToSync} ssh://$servers{$server_id}{host}/$servers{$server_id}{pathOfFilesToSync}";
	
		#for the second run we don't need bidirectional syncinng as we just destributing the canges from the later sync servers.
		if ( $servers{$server_id}{type} eq 'slave' or $runIdentifier eq "second" or $runIdentifier eq "secondretry") {
			$command = $command . " -nocreation $servers{1}{pathOfFilesToSync}  -noupdate $servers{1}{pathOfFilesToSync}";
		}
	
		local *CATCHERR = IO::File->new_tmpfile;
		my $pid = open3( gensym, \*CATCHOUT, ">&CATCHERR", $command );
	
		waitpid( $pid, 0 );
		seek CATCHERR, 0, 0;
	
		#if there was an error during the sync print all output, send emails and stop the execution
		while (<CATCHERR>) {
			errorMessage( 'critical', $_ );
		}
	
		while (<$unisonLogFileFh>) {
			if ( $_ =~ /Synchronization\scomplete\sat.*/ ) {
				$fileSyncSummary =
				    $fileSyncSummary
				  . "Synced files between $servers{1}{host}/$servers{$server_id}{pathOfFilesToSync}"
				  . " and $servers{$server_id}{host}/$servers{$server_id}{pathOfFilesToSync}\n"
				  . $_;
	
				print $_;
			}
		}
	
		#run postexecution command
		print "run postexecution command on server " . $servers{$server_id}{host} . "\n";
		$db = connectToMySQLServer ($server_id);
		
		if (!$db) {
				errorMessage( 'warning', "could not run postexecution command on " . $servers{$server_id}{host} . "\n" );
		} else {
		
			$db->do( $postExecutionSQLcommand, undef, $server_id );
		
			if ( defined $DBI::errstr ) {
				errorMessage( 'warning', "could not run postexecution command on " . $servers{$server_id}{host} . "\n$DBI::errstr\n" );
		
			}
		
		$db->disconnect;
		}
	}
}

sub wrileSyncLog {
	my $write_type			= $_[0];
	my $server_id			= $_[1];
	my $server_to_change	= $_[2];
	my $table				= $_[3];
	my $record_id 			= $_[4];
	my $sql_statement 		= $_[5];
	my $host_id_from 		= 1;
	my $host_id_to 			= 1;
	my $change_log;
	my $sync_log;
	my $comment = "unknown";
	my $user_email = "unknown";
	my $user_name = "unknown";
	my $user_id = "unknown";
	my $user_firstname = "unknown";
	my $user_lastname = "unknown";
	my $time_of_change_on_remote_server = "NOW() - INTERVAL 60 SECOND"; #just to get something between now and the last sync
	
	my $print_string;
	
	if ($server_to_change ne $servers{$server_id}{host}) {
		$host_id_from = $server_id;
	} else {
		$host_id_to = $server_id;
	}
	

	
	
	#get details about the user wrote that change
	#The UNION in the Subquery makes sure  there is a date even if the server was never synct before
	$sql = "SELECT  `change_log`.`timestamp` ,
						`change_log`.comment,
						`users`.`id`,
						`users`.`email`,
						`users`.`name`,
						`users`.`lastname`,
						`users`.`user_name`,
						COUNT(*) AS count
				FROM `change_log`
				JOIN `users` ON `change_log`.`user_id` = `users`.`id`
				WHERE `table` = ?
						AND `record_id` = ?
						AND `change_log`.`timestamp` > 
							(
							SELECT this_time FROM `sync` WHERE sync_from = ? 
														 AND sync_to = ?
							UNION SELECT '0000-00-00' 
							ORDER BY this_time DESC LIMIT 1
							)
				ORDER BY `change_log`.`timestamp` DESC
				LIMIT 1";

	#see if we have a entry in the change_log
	$print_string= "Get changelog from ".$servers{$host_id_from}{host} . " for writing sync_log\n";
	print $print_string;
	$verboseOutput = $verboseOutput . "\n". $print_string;

	
	my $db = connectToMySQLServer ($host_id_from);
	if (!$db && $host_id_from != 1) {
		errorMessage( 'warning', "could not get the changelog from: " . $servers{$host_id_from}{host} . "\n" );	
	} elsif (!$db && $host_id_from == 1) {
		#not beeing able to connect to MySQL on ther hub server is a critical error
		errorMessage( 'critical', "could not connect to MySQL server on: " . $servers{$host_id_from}{host} . "\n$DBI::errstr\n" );
	} else {		
		
		$change_log = $db->selectrow_hashref( $sql, undef, $table, $record_id, $host_id_to,$host_id_from );
		if ( defined $DBI::errstr ) {
	
			if ($DBI::errstr =~ $warning_errors) {
				
				errorMessage( 'warning', "could not get the changelog from: " . $servers{$host_id_from}{host} . "\n$DBI::errstr\n" );
	
			}
			#anything else will lead to an abbort
			else {
			   errorMessage( 'critical', "could not get the changelog from: " . $servers{$host_id_from}{host} . "\n$DBI::errstr\n" );
	
			}	
		}
		
		$comment = $change_log->{'comment'};
		$user_email = $change_log->{'email'};
		$user_name = $change_log->{'user_name'};
		$user_id = $change_log->{'id'};
		$user_firstname = $change_log->{'name'};
		$user_lastname = $change_log->{'lastname'};
		$time_of_change_on_remote_server = $change_log->{'timestamp'};


	
	$db->disconnect;	
	}
	if ($change_log->{'count'}  == 0 && $host_id_from == 1) {
		#we could not find the change in the changelog, so lets check the sync_log
		
		#print "get changes from sync_log\n";

		$sql = "SELECT  `timestamp`,
						`user_name`,
						`user_id`,
						`user_email`,
						`user_firstname`,
						`user_lastname`,
						`time_of_change_on_remote_server`,
						`comment`
					FROM `sync_log`

					WHERE `table` = ?
							AND `record_id` = ?
							AND `site_id_to` = 1
							AND `time_of_change_on_remote_server` > 
								(
								SELECT this_time FROM `sync` WHERE sync_from = ? 
								AND sync_to = 1
								UNION SELECT '0000-00-00' 
								ORDER BY this_time DESC LIMIT 1
								)
					ORDER BY `timestamp` DESC
					LIMIT 1";	

		$sync_log = $dbh{1}->selectrow_hashref( $sql, undef, $table, $record_id,$host_id_from );

		if ( defined $DBI::errstr ) {
			errorMessage( 'critical', "could not get the sync_log \n$DBI::errstr\n" );
		} else {
			$comment = $sync_log->{'comment'};
			$user_email = $sync_log->{'user_email'};
			$user_name = $sync_log->{'user_name'};
			$user_id = $sync_log->{'user_id'};
			$user_firstname = $sync_log->{'user_firstname'};
			$user_lastname = $sync_log->{'user_lastname'};
			$time_of_change_on_remote_server = $sync_log->{'time_of_change_on_remote_server'};
		}

	
	}
	
	my $sql       = "INSERT INTO sync_log (
								`site_id_from`,
								`site_id_to`,
								`table`,
								`record_id`,
								`update_type`,
								`time_of_change_on_remote_server`,
								`user_id`,
								`user_email`,
								`user_firstname`,
								`user_lastname`,
								`user_name`,
								`comment`,
								`sql`) 
						VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)";
	
	if ($write_type ne "UPDATE" and $write_type ne "INSERT") {
		errorMessage( 'critical', "the write_type in the writeSyncLog function can just be UPDATE or INSERT\n" );
	}
	
	
	$dbh{1}->do( $sql, undef, @{[$host_id_from, 
								 $host_id_to,
								 $table,
								 $record_id,
								 $write_type,
								 $time_of_change_on_remote_server,
								 $user_id,
								 $user_email,
								 $user_firstname,
								 $user_lastname,
								 $user_name,
								 $comment,
								 $sql_statement]});
	if ( defined $DBI::errstr ) {
		errorMessage( 'critical', "could not write sync_log  \n$DBI::errstr\n" );
	}	
	
	
}



sub stampServer {
	my $server_id_to_stamp      = $_[0];
	my $server_id_got_data_from = $_[1];
	my $sql_for_sync_stamp       = "INSERT INTO sync (sync_from,sync_to,this_time) VALUES (?,?,NOW())
 			  			  			ON DUPLICATE KEY UPDATE last_time=this_time, this_time=NOW();";

	print "Stamping Server $servers{$server_id_to_stamp}{host} to be sync from $servers{$server_id_got_data_from}{host}\n";

	#we just stamp if the server we supposedly got data from is a master
	#as no server should not get ever data from a slave, we don't stamp server as sync_from a slave
	if ( $servers{$server_id_got_data_from}{'type'} eq 'master' ) {

		my $db = connectToMySQLServer ($server_id_to_stamp);
		if (!$db) {
			errorMessage( 'warning', "could not stamp  " . $servers{$server_id_to_stamp}{host} . "\n" );	
		}
		else {	
			$db->do( $sql_for_sync_stamp, undef, $server_id_got_data_from,$server_id_to_stamp);
			if ( defined $DBI::errstr ) {
				errorMessage( 'warning', "could not stamp  " . $servers{$server_id_to_stamp}{host} . "\n$DBI::errstr\n" );
			}
			$db->disconnect;
		}
		$dbh{1}->do( $sql_for_sync_stamp, undef, $server_id_got_data_from,$server_id_to_stamp);
	}
}

#$_[0] is the level and can be "warning" or "critical", warning prints the message, critical stops the execution
#$_[1] is the actual error message
sub errorMessage {
	my $print_string;
	my %error;
	
	$error{level} = $_[0];
	$error{message} = $_[1];
	$error{server_id} = $_[2];
	
	push @errors, {%error};
	
	#$errorOutput = $errorOutput . $error{message};

	if ( $error{level} eq "critical" ) {
		#$errorOutput = "CRITICAL ERROR:\n----------------- \n" . $errorOutput . "\n ----------------- STOP execution\n";
		printErrorsAndSummary();
		sendAdministratorEmail();
		die;
	}
	elsif ( $error{level} eq "retry" ) {
		$print_string= "RETRY ERROR:\n" . $error{message} . "\nWe will stop syncing the server " . $servers{$error{server_id}}{host} . " and try later again\n\n";
		$verboseOutput = $verboseOutput .  $print_string;
		print $print_string;
  		if (!exists $servers_to_retry{$error{server_id}})
			{			
  	  			$servers_to_retry{$error{server_id}}=1;
			}

	}
	else {
		$print_string = "WARNING:\n " . $error{message} . "\n";
		$verboseOutput = $verboseOutput .  $print_string;
		print $print_string;
		
	}
}

sub printErrorsAndSummary {

	my @warnings = grep { $_->{level} eq 'warning' } @errors;
	my $warningsText;
	if (scalar (@warnings) > 0) {
		
	
		$warningsText = "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
		$warningsText = $warningsText . "WARNINGS:\n";
		foreach (@warnings) {
			
			$warningsText = $warningsText . $_->{message} . "\n----------------------------------------------\n";
			$emailSubjectPostfix         = " finished with WARNINGS!";
		}
		
		$warningsText = $warningsText . "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n";
			
		print $warningsText;
		$errorOutput = $errorOutput . $warningsText;	
	}
		


	my @retryErrors = grep { $_->{level} eq 'retry' } @errors;
	my $retryErrorsText;
	if (scalar (@retryErrors) > 0) {
		
		$retryErrorsText = "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
		$retryErrorsText = $retryErrorsText . "ERRORS THAT CAUSES A RETRY OF SYNC:\n";
		foreach (@retryErrors) {
			$retryErrorsText = $retryErrorsText . $_->{message} . "\n----------------------------------------------\n";		
		}
		
		$retryErrorsText = $retryErrorsText . "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n";
			
		print $retryErrorsText;
		$errorOutput = $errorOutput . $retryErrorsText;	
	}


	my @criticalErrors = grep { $_->{level} eq 'critical' } @errors;
	my $criticalErrorsText;
	if (scalar (@criticalErrors) > 0) {	
		
		$criticalErrorsText = "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
		$criticalErrorsText = $criticalErrorsText . "CRITICAL ERROR:\n";
		$criticalErrorsText = $criticalErrorsText . $criticalErrors[0]->{message} . "\n";
		$criticalErrorsText = $criticalErrorsText . "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n";
			
		print $criticalErrorsText;
		$errorOutput = $errorOutput . $criticalErrorsText;	
		$emailSubjectPostfix         = " ERROR - could not finish syncronization!";
	}

	$syncSummary =
	    $syncSummary
	  . "###############################################################################################\n"
	  . "DATABASE SYNC SUMMARY:\nInserted Items: $insertCount\nUpdated Items: $updateCount\nConflicts: "
	  . ( $#conflicts + 1 )
	  . "\ncheck the attached file database_syncronisation_verbose_informations.txt for more information"
	  . "\n###############################################################################################\n";

	print "\n\n" . $syncSummary;

	$fileSyncSummary =
	    "###############################################################################################\n"
	  . "FILE SYNC SUMMARY:\n"
	  . $fileSyncSummary
	  . "\ncheck the attached file file_syncronisation_verbose_informations.txt for more information"
	  . "\n###############################################################################################\n";

	print "\n\n" . $fileSyncSummary;

}

sub sendAdministratorEmail {

	my $administratorEmailData = "";
	my $verboseOutputFH;
	my $verboseOutputFile;

	# try new temporary filenames until we get one that didn't already exist
	do { $verboseOutputFile = tmpnam() } until $verboseOutputFH = IO::File->new( $verboseOutputFile, O_RDWR | O_CREAT | O_EXCL );

	# install atexit-style handler so that when we exit or die,
	# we automatically delete this temporary file

	if ( $errorOutput ne "" ) {
		$administratorEmailData = $errorOutput . "\n";
	}

	#write verbose informations to file
	print $verboseOutputFH "VERBOSE INFORMATION:\n$verboseOutput\n";
	print $verboseOutputFH "###############################################################################################\n";
	undef $verboseOutputFH;

	$administratorEmailData = $administratorEmailData . $syncSummary . $fileSyncSummary;

	my $msg = MIME::Lite->new(
							   From    => $emailFromAddress,
							   To      => $administratorAddresses,
							   Subject => 'INF personnel database syncronization report!' . $emailSubjectPostfix,
							   Type    => 'TEXT',
							   Data    => $administratorEmailData
	);

### Attach a part... the make the message a multipart automatically:
	$msg->attach(
				  Type     => 'text/plain',
				  Path     => $verboseOutputFile,
				  Filename => 'database_syncronisation_verbose_informations.txt'
	);

	if ( -e $unisonLogFile ) {
		$msg->attach(
					  Type     => 'text/plain',
					  Path     => $unisonLogFile,
					  Filename => 'file_syncronisation_verbose_informations.txt'
		);
	}

	print "Send Email to administrator ... \n";
	$msg->send;

	unlink($verboseOutputFile) or die "Couldn't delete unison log file: $verboseOutputFile : $!";
}

sub connectToMySQLServer {
	my $server_id   = $_[0];
	
	my $db = DBI->connect( 'DBI:mysql:' . $servers{$server_id}{database} . ';host=' . $servers{$server_id}{host}.';mysql_connect_timeout='.$mysql_connect_timeout.';mysql_read_timeout='. $mysql_read_timeout,
					$servers{$server_id}{username},
					$servers{$server_id}{password} );
					
	if ( defined $DBI::errstr ) {
		return 0;
	} else {
		return $db;
	}
}

