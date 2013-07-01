#!/usr/bin/perl

#Autor: Artur Neumann INF/N ict.projects@nepal.inf.org
#Version: see $version variable
#last change: 2013.06.25
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
my $version = "2.2";
my $ptTableSync = "/usr/bin/pt-table-sync";    #install from http://www.percona.com/doc/percona-toolkit/2.1/installation.html
my $syncCommandAdditionalAttributes = " --print --execute --conflict-comparison newest --verbose --conflict-error die --function MD5";
my $emailFromAddress                = 'yourmail@company.org';
my $unison                   = "/usr/bin/unison";               #to install on ubunto run 'sudo apt-get install unison'
my $conflictEmailCCAddresses = 'yourmail@company.org';    #separate addresses by comma
my $administratorAddresses   = 'yourmail@company.org';    #addresses the output of the script will be send
my $preExecutionSQLcommand  = "UPDATE `site` SET `maintenance` = '0' WHERE `site_specific_id` =?;";
my $postExecutionSQLcommand = "UPDATE `site` SET `maintenance` = '0' WHERE `site_specific_id` =?;";

#use this line send emails via sendmail
#MIME::Lite->send('sendmail');

#use this line to send emails direct via SMTP
#if you use this you also need to enable the two lines above:
#use Authen::SASL; and #use MIME::Base64;

MIME::Lite->send( 'smtp', "company.org", AuthUser => 'mail@company.org', AuthPass => 'xxxx' );

#list of servers in the network
my @servers = (
        {

           #this must be the server this script runs on, its the main one
           host     => "localhost",
           database => "dbname",
           username => "db-sync-user",
           password => "db-syncpasword",
           type     => "master",                  #the first server must be a master, it writes data to other servers
           id       => "1",                       #this number must be the same id as in the auto_increment_offset variable in the my.cnf config file
                                                       #AND the site_specific_id  in the site table
           pathOfFilesToSync => "/var/www/fileUploads/"    #absolute path of the files that have to be synced.
        },
        {
           host     => "hosta.ngo.org",
           database => "dbname",
           username => "db-sync-user",
           password => "db-syncpasword",
           type     => "master",                   #can be "master" OR "slave"
                                                  #a master server will write his data to all other servers
                                                  #so between master servers datachanges will be sync bidirectional
                                                  #a slave server is not allowed to write data to other servers,
                                                  #a slave server will just receive data and all changes on a slave
                                                  #server will be overwritten at the next sync by data from the master server(s)
           id       => "2",
           pathOfFilesToSync => "/var/www/fileUploads/"    #absolute path of the files that have to be synced.

        },
        {
           host     => "hostb.ngo.org",
           database => "dbname",
           username => "db-sync-user",
           password => "db-syncpasword",
           type     => "slave",                   #can be "master" OR "slave"
           id       => "3",
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
my %servers_to_retry;
my @dbh;
my $insertCount     = 0;
my $updateCount     = 0;
my $syncSummary     = "Version: $version \nSync started at: " . strftime( '%d-%m-%Y %H:%M', localtime ) . "\n\n";
my $fileSyncSummary = "";
my $verboseOutput   = $syncSummary;
my $errorOutput     = "";
my $unisonLogFile   = "";
my $errorString;
my $fields_hash;

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
for my $server_num ( 0 .. $#servers ) {

	print "Connecting ... host: $servers[$server_num]{host}  database:$servers[$server_num]{database}  \n";
	my $db = DBI->connect( 'DBI:mysql:' . $servers[$server_num]{database} . ';host=' . $servers[$server_num]{host}.';mysql_connect_timeout=5;mysql_read_timeout=1',
					$servers[$server_num]{username},
					$servers[$server_num]{password} );
				
	push @dbh, $db;
	

	if ( defined $DBI::errstr ) {
		$errorString = "\nCould not connect to database on server $servers[$server_num]{host}\n $DBI::errstr\n";

		#if we have a problem with the first server (the main one and the one running this script), we cannot proceed
		if ( $server_num == 0 ) {
			errorMessage( 'critical', $errorString );
		}

		#if it not the main server, we just remove the server from the list and sync the rest
		else {
			errorMessage( 'warning', $errorString . "We will not sync this server and proceed with the next one (if any)\n\n" );
			$servers[$server_num]{type} = "delete";
			next;
		}
	}

	print "Cheking database structure ... \n";
	foreach my $table (@tableData) {

		$sql = "show columns from `@$table[0]`";
		$fields_hash = $dbh[$server_num]->selectall_hashref( $sql, "Field", \%DBattr );

		#check if table exists
		if ( defined $DBI::errstr ) {

			$errorString = "\nDatabase Error on server $servers[$server_num]{host}\n $DBI::errstr\n";

			#if we have a problem with the first server (the main one and the one running this script), we cannot proceed
			if ( $server_num == 0 ) {
				errorMessage( 'critical', $errorString );
			}

			#if it not the main server, we just remove the server from the list and sync the rest
			else {
				errorMessage( 'warning', $errorString . "We will not sync this server and proceed with the next one (if any)\n\n" );
				$servers[$server_num]{type} = "delete";
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
				  . $servers[$server_num]{host}
				  . " or its not of type 'timestamp' - please doublecheck the \@tableData list and the database on the server\n"
				  . "We will not sync this server and proceed with the next one (if any)\n\n";

				errorMessage( 'warning', $errorString );
				$servers[$server_num]{type} = "delete";
				last;

			}
		}
	}

	print "run preexecution comman on server " . $servers[$server_num]{host} . "\n";
	$dbh[$server_num]->do( $preExecutionSQLcommand, undef, $servers[$server_num]{'id'} );

	if ( defined $DBI::errstr ) {
		errorMessage( 'warning', " could not run preexecution comman on " . $servers[$server_num]{host} . "\n$DBI::errstr\n We will not sync this server and proceed with the next one (if any)\n\n" );
		$servers[$server_num]{type} = "delete";
	}
}

#delete Servers with type==delete
deleteMarkedServers();

my $command;
my $change_log;
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
for my $server_num ( 1 .. $#servers ) {
	syncServer( "first", $server_num );
}

#retry syncing failed servers
print "Servers to retry:" . %servers_to_retry . "\n";


foreach my $servernum_to_retry (keys %servers_to_retry){
	syncServer( "firstretry", $servernum_to_retry );
}


#delete all servers that could not be synced even after a retry
deleteMarkedServers();

#count the remaining master servers
for my $server_num ( 0 .. $#servers ) {
	if ( $servers[$server_num]{type} eq "master" ) {
		$count_master_servers = $count_master_servers + 1;
	}
	
}

#if we have more than 2 masters we need to sync again
#but also if there are just two masters and there are slaves between servers[0] and the second master
#these slaves have to be sync again to get the data from the second master
#there is also no need to sync again in there were no changes made at all
if (( $count_master_servers > 2 || ( $count_master_servers == 2 && $servers[1]{type} ne "master" )) 
	  && ($insertCount > 0 || $updateCount > 0) ) {

	%servers_to_retry=();
	
	#sync every server (exept the last one) again to distribute the changes from the later servers to the earlier ones
	for my $server_num ( 1 .. $#servers) {
		syncServer( "second", $server_num );
	}
	
	#retry the failed ones
	foreach my $servernum_to_retry (keys %servers_to_retry){
		syncServer( "secondretry", $servernum_to_retry );
	}	


	#delete all servers that could not be synced even after a retry
	deleteMarkedServers();

}

#running the postexecution command on every server
for my $server_num ( 0 .. $#servers ) {

	print "run postexecution comman on server " . $servers[$server_num]{host} . "\n";
	my $db = connectToMySQLServer ($server_num);
	
	if (!$db) {
			errorMessage( 'warning', "could not run postexecution comman on " . $servers[$server_num]{host} . "\n" );
	} else {
	
		$db->do( $postExecutionSQLcommand, undef, $servers[$server_num]{'id'} );
	
		if ( defined $DBI::errstr ) {
			errorMessage( 'warning', "could not run postexecution comman on " . $servers[$server_num]{host} . "\n$DBI::errstr\n" );
	
		}
	
	$db->disconnect;
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
	my $server_num = 0;
	while ( $server_num <= $#servers ) {
		if ( $servers[$server_num]{type} eq "delete" ) {
			splice( @servers, $server_num, 1 );
			splice( @dbh,     $server_num, 1 );
		}
		else {
			$server_num++;
		}
	}

}

sub checkForConflicts {

	
	my $host_to_change = $_[0];
	my $record_id      = $_[1];
	my $table_name     = $_[2];
	my $server_num     = $_[3];
	my $server_num_with_most_recent_change;
	my $server_to_check_for_conflicts_num;
	my $time_of_oldest_log->{'this_time'} = '000-00-00';
	print "Check for conflicts. record_id=$record_id Table: $table_name\n";

	#before the UPDATE statement the pt-sync-table tools shows us the server that was updated
	#so the other one is the one with the most recent changes
	#As we always sync from $server[0], the server with the most recent data must be either $server[0] or
	#the one we are syncing just now.
	if ( $host_to_change eq $servers[0]{host} ) {
		$server_num_with_most_recent_change = $server_num;
	}
	else {
		$server_num_with_most_recent_change = 0;
	}

	#check if there is a conflict with this table and record_id
	#if yes we will have to see who is the real winner and we don't need to check the other servers for
	#conflicts because we have done this already
	my $conflicts_exists = 0;
	foreach my $conflict (@conflicts) {
		if (    $conflict->{'table'} eq $table_name
			 && $conflict->{'record_id'} eq $record_id)
		{
			$conflicts_exists = 1;

			#if the actual server we are sycing with $server[0] is the winner, we have a new winner
			#and we need to update the conflicts array
			if ( $server_num_with_most_recent_change == $server_num ) {

				#the former winner is now also a looser
				push( @{ $conflict->{'loosing_parties'} }, dclone $conflict->{'winning_party'} );

				#find the new winner in the looser list, make it a winner and delete it from the looser list
				#TODO can this realy ever happen?
				for ( my $i = 0 ; $i < @{ $conflict->{'loosing_parties'} } ; $i++ ) {
					if ( $conflict->{'loosing_parties'}[$i]{'server'}{'id'} eq $servers[$server_num_with_most_recent_change]{'id'} ) {
						$conflict->{'winning_party'} = dclone $conflict->{'loosing_parties'}[$i];
						splice( $conflict->{'loosing_parties'}, $i, 1 );
						last;
					}
				}
			}
			last;
		}
	}

	my %conflict;

	#No need to check the other servers if we have the conflict already in our list
	if ( $conflicts_exists == 0 ) {

		#check for conflicts on all hosts exept the one with the most recent change
		#a conflict is when there were an update on the same record since the last sync
		#print "Checking for conflicts on other servers\n";
		for $server_to_check_for_conflicts_num ( 0 .. $#servers ) {

			#we just need to check master-servers, because slaves will be overwritten anyway
			#and the server that has the most recent change don't need to be checked
			if (    $server_to_check_for_conflicts_num != $server_num_with_most_recent_change
				 && $servers[$server_to_check_for_conflicts_num]{type} eq "master" )
			{

				#print $servers[$server_to_check_for_conflicts_num]{host} . "\n";

				#The UNION in the Subquery makes sure  there is a date even if the server was never synct before
				$sql = "SELECT  `change_log`.`timestamp` ,
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
				print "Get changelog from ".$servers[$server_to_check_for_conflicts_num]{host} . "\n";
								
				my $db = connectToMySQLServer ($server_to_check_for_conflicts_num);
				
				if (!$db) {
					errorMessage( 'warning', "could not check for conflicts on " . $servers[$server_to_check_for_conflicts_num]{host} . "\n" );
					
				} else {
					$change_log = $db->selectrow_hashref( $sql, undef, $servers[$server_num_with_most_recent_change]{id} );
					if ( defined $DBI::errstr ) {
	
						if ($DBI::errstr =~ /.*?Lost connection to MySQL server during query.*?/ or 
							$DBI::errstr =~ /.*?Can\'t connect to MySQL server.*?/ or
							$DBI::errstr =~ /.*?MySQL server has gone away.*?/) {
							
							errorMessage( 'warning', "could not check for conflicts on " . $servers[$server_to_check_for_conflicts_num]{host} . "\n$DBI::errstr\n" );
	
						}
						#anything else will lead to an abbort
						else {
						   errorMessage( 'critical', "could not check for conflicts on " . $servers[$server_to_check_for_conflicts_num]{host} . "\n$DBI::errstr\n" );
	
						}
					}
					
					$db->disconnect;
					}
				
				if ( defined $change_log ) {

					#now we discovered a real conflict (the same row in the same table is changed on least two servers between
					#the last sync and now)

					#we found a loosing party
					#for cheking who is winner and who is looser we trust pt-table-sync and NOT the timestamps in the
					#change_log table
					#pt-table-sync tould us already that it updated one of the servers, so we know for sure this one
					#is a looser.
					#if there are more than two servers in the system, and there is a conflict between 3 or more servers
					#we first call the server we didn't sync yet also a looser, it might become the real winner when we
					#sync it. But we want to know it from pt-table-sync

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
					$loosing_party{'server'}{'host'}      = $servers[$server_to_check_for_conflicts_num]{'host'};
					$loosing_party{'server'}{'id'}        = $servers[$server_to_check_for_conflicts_num]{'id'};
					push( @{ $conflict{'loosing_parties'} }, {%loosing_party} );

				}

			}
		}

		#if we had at least one conflict, we need to collect some more data about it
		if ( defined $conflict{'loosing_parties'} && @{ $conflict{'loosing_parties'} } ) {

			#collect the data of the conflict
			$conflict{'table'}     = $table_name;
			$conflict{'record_id'} = $record_id;

			$sql = "SELECT this_time FROM `sync` WHERE";
			foreach ( @{ $conflict{'loosing_parties'} } ) {
				$sql = $sql . " sync_from = $_->{'server'}{'id'} OR ";
			}

			$sql = substr( $sql, 0, length($sql) - 3 );
			$sql = $sql . " ORDER BY this_time ASC LIMIT 1";

			print "Get get time of the oldest log: $servers[$server_num_with_most_recent_change]{host}\n";
			
			my $db = connectToMySQLServer ($server_num_with_most_recent_change);
			if (!$db) {
				errorMessage( 'warning', "could not get conflict member information from: " . $servers[$server_num_with_most_recent_change]{host} . "\n" );
				
			}
			else {
				$time_of_oldest_log = $db->selectrow_hashref($sql);
				if ( defined $DBI::errstr ) {
					errorMessage( 'warning', "could not get conflict member information from: " . $servers[$server_num_with_most_recent_change]{host} . "\n$DBI::errstr\n" );
				} else {
	
					if ( not defined $time_of_oldest_log ) {    #if there were no sync before use 0000-00-00 as time
						$time_of_oldest_log->{'this_time'} = '000-00-00';
					}
		
					#get the data of the winner
					$sql = "SELECT  `change_log`.`timestamp` ,
											`change_log`.comment,
											`users`.`email`,
											`users`.`name`,
											`users`.`lastname`,
											`users`.`user_name`
									FROM `change_log`
									JOIN `users` ON `change_log`.`user_id` = `users`.`id`
									WHERE `table` = '$table_name'
											AND `record_id` = '$record_id'
											AND `change_log`.`timestamp` > '$time_of_oldest_log->{'this_time'}'
									ORDER BY `change_log`.`timestamp` DESC
									LIMIT 1";
		
					print "Get more information about the conflict from: " . $servers[$server_num_with_most_recent_change]{host} . "\n";
					$change_log = $db->selectrow_hashref($sql);
		
					if ( defined $DBI::errstr ) {
						errorMessage( 'warning', "could not get conflict member information from: " . $servers[$server_num_with_most_recent_change]{host} . "\n$DBI::errstr\n" );
					}
				}
				
				$db->disconnect;
			}
			#The information aber the conflict party could not be found on this server 
			#probably the conflict was caused by an other server and the server that just send the changes was synced but
			#the one just received the changes was not online at that time to be checked for conflicts
			if (!defined $change_log->{'user_name'}) {

				errorMessage( 'warning', "could not find information about the winning party on: " . $servers[$server_num_with_most_recent_change]{host} . "\nProbably there was a network problem during the last sync\ntry to get information about winning party from sync_log\n" );
								
				$sql = "SELECT  `sync_log`.`comment`,
								`sync_log`.`site_id_from`
								FROM `sync_log`
								
								WHERE `table` = '$table_name'
										AND `record_id` = '$record_id'
										AND `timestamp` > '$time_of_oldest_log->{'this_time'}'
										AND `user_id` IS NOT NULL
										AND `site_id_to` = $servers[0]->{'id'}
								ORDER BY `timestamp` DESC
								LIMIT 1";				
				
				#TODO sollen wir hier auch zu $db ändern?
				my $sync_log = $dbh[0]->selectrow_hashref($sql);

				$change_log = eval $sync_log->{'comment'};
				$change_log = $change_log->{'user_info'};
				
				$conflict{'winning_party'}{'server'}{'id'}        = $sync_log->{'site_id_from'};
				
				#TODO das ist doch mist id und num sollte das gleiche sein
				for my $server_num ( 0 .. $#servers ) {
					if ($conflict{'winning_party'}{'server'}{'id'}  == $servers[$server_num]{'id'}) {
						$conflict{'winning_party'}{'server'}{'host'}      = $servers[$server_num]{'host'};
						last;
					}
				}				
				
				
			} else {
				$conflict{'winning_party'}{'server'}{'host'}      = $servers[$server_num_with_most_recent_change]{'host'};
				$conflict{'winning_party'}{'server'}{'id'}        = $servers[$server_num_with_most_recent_change]{'id'};				
			}

			$conflict{'winning_party'}{'comment'}             = $change_log->{'comment'};
			$conflict{'winning_party'}{'person'}{'email'}     = $change_log->{'email'};
			$conflict{'winning_party'}{'timestamp'}           = $change_log->{'timestamp'};
			$conflict{'winning_party'}{'person'}{'full_name'} = $change_log->{'name'} . " " . $change_log->{'lastname'};
			$conflict{'winning_party'}{'person'}{'user_name'} = $change_log->{'user_name'};


			push @conflicts, {%conflict};

		}
	}
}

sub syncServer {
	my $runIdentifier   = $_[0]; #can be: "first,second,firstretry,secondretry"
	my $server_num = $_[1];
	my $stopSyncingThisServer = 0; #will be set to 1 in case of a "retry" error
	my $print_string;

	foreach my $table (@tableData) {
		$command = "$ptTableSync ";

		#for the second run we don't need bidirectional syncinng as we just destributing the canges from the later sync servers.
		if ( $servers[$server_num]{type} eq 'master'  and ($runIdentifier eq "first" or $runIdentifier eq "firstretry")) {
			$command = $command . " --bidirectional ";
		}
		$command =
		    $command
		  . "h=$servers[0]{host},D=$servers[0]{database},t=@$table[0],u=$servers[0]{username},p=$servers[0]{password} "
		  . "h=$servers[$server_num]{host},D=$servers[$server_num]{database},u=$servers[0]{username},p=$servers[$server_num]{password} "
		  . " --conflict-column @$table[1] $syncCommandAdditionalAttributes";
		
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
		

		$print_string = " server: $servers[$server_num]{host} -  table : '@$table[0]' - conflict column: '@$table[1]'\n";
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
			if ($sql_statement =~ /\/\*(.*)\*\/ UPDATE `($servers[0]{database}|$servers[$server_num]{database})`.`@$table[0]`.*WHERE `id`=\'(\d+)\' LIMIT 1\;/ ) 
			{
				
				$updateCount = $updateCount + 1;
				#before the UPDATE statement the pt-sync-table tools shows us the server that was updated this is $1
				my $host_to_change = $1;
				my $record_id = $3;
				
				wrileSyncLog('UPDATE',$server_num,$host_to_change,@$table[0],$record_id,$sql_statement);
			
				#in the first round of syncing we have to check for conflicts. But we don't need the conflict checks in the second
				#round of syncing, because all conflict information should be there after the first round.
				if ($runIdentifier eq "first" or $runIdentifier eq "firstretry")
				{
					
					#we just need to check for conflicts if the server we just updated was a master server
					#slaves will be overwritten anyway
					for my $server_to_check_for_conflicts_num ( 0 .. $#servers ) {
						if ( $servers[$server_to_check_for_conflicts_num]{host} eq $host_to_change ) {
							if ( $servers[$server_to_check_for_conflicts_num]{type} eq 'master' ) {
								checkForConflicts( $host_to_change, $record_id, @$table[0], $server_num );
							}
							last;
						}
					}
				}
				
			} 
			#this case hapends for the one way syncs
			elsif ($sql_statement =~ /UPDATE `($servers[0]{database}|$servers[$server_num]{database})`.`@$table[0]`.*WHERE `id`=\'(\d+)\' LIMIT 1\s+\/\*percona-toolkit src_db:($servers[0]{database}|$servers[$server_num]{database}) src_tbl:@$table[0] src_dsn:D=($servers[0]{database}|$servers[$server_num]{database}),h=(.*),p=...,t=@$table[0],.* dst_db:($servers[0]{database}|$servers[$server_num]{database}) dst_tbl:@$table[0] dst_dsn:D=.*,h=(.*),p=.*/) {
				$updateCount = $updateCount + 1;
				my $host_to_change = $7;	
				my $record_id = $2;			
				wrileSyncLog('UPDATE',$server_num,$host_to_change,@$table[0],$record_id,$sql_statement);				
				
			} 
			elsif ($sql_statement =~ /\/\*(.*)\*\/ INSERT INTO `($servers[0]{database}|$servers[$server_num]{database})`.`@$table[0]`.* VALUES \('(\d+)',.*\)\;/) {

				$insertCount = $insertCount + 1;
				
				#before the INSERT statement the pt-sync-table tools shows us the server that was updated this is $1
				my $host_to_change = $1;	
				my $record_id = $3;			
				wrileSyncLog('INSERT',$server_num,$host_to_change,@$table[0],$record_id,$sql_statement);
			} 
			elsif ($sql_statement =~ /INSERT INTO `($servers[0]{database}|$servers[$server_num]{database})`.`@$table[0]`.* VALUES \('(\d+)',.*\)\s+\/\*percona-toolkit src_db:($servers[0]{database}|$servers[$server_num]{database}) src_tbl:@$table[0] src_dsn:D=($servers[0]{database}|$servers[$server_num]{database}),h=(.*),p=...,t=@$table[0],.* dst_db:($servers[0]{database}|$servers[$server_num]{database}) dst_tbl:@$table[0] dst_dsn:D=.*,h=(.*),p=.*/) {

				$insertCount = $insertCount + 1;

				my $host_to_change = $7;	
				my $record_id = $2;			
				wrileSyncLog('INSERT',$server_num,$host_to_change,@$table[0],$record_id,$sql_statement);				
			}
		}

		waitpid( $pid, 0 );
		seek CATCHERR, 0, 0;

		#if there was an error during the sync check the severity
		while (<CATCHERR>) {
				#when this errors occure we will try it again
				if ($_ =~ /.*Lost connection to MySQL server during query.*/ or 
							$_ =~ /.*Can\'t connect to MySQL server.*/ or
							$_ =~ /.*MySQL server has gone away.*/ or
							$_ =~ /.*Issuing rollback.*/) {
					
					$stopSyncingThisServer=1;
					#if its already the retry run then mark the server as to be deleted and give a warning
					if ($runIdentifier eq 'firstretry' or $runIdentifier eq 'secondretry') {
						errorMessage( 'warning',  $_);
						$servers[$server_num]{type} = "delete";
						$stopSyncingThisServer=1;
					}
					
					#if the error comes the first time we will retry to sync the server later
					else {
						errorMessage( 'retry',  $_, $server_num);
						
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

##now we are sync the files

	#we don't try to sync the files if the sync was aborted during the database sync
	if ($stopSyncingThisServer == 0) {

		print "Syncing files with $servers[$server_num]{host}\n";
	
		$command =
		    "$unison -silent  -logfile $unisonLogFile -ui text -batch "
		  . " -nodeletion $servers[0]{pathOfFilesToSync}  -nodeletion ssh://$servers[$server_num]{host}/$servers[$server_num]{pathOfFilesToSync}"
		  . " $servers[0]{pathOfFilesToSync} ssh://$servers[$server_num]{host}/$servers[$server_num]{pathOfFilesToSync}";
	
		#for the second run we don't need bidirectional syncinng as we just destributing the canges from the later sync servers.
		if ( $servers[$server_num]{type} eq 'slave' or $runIdentifier eq "second" or $runIdentifier eq "secondretry") {
			$command = $command . " -nocreation $servers[0]{pathOfFilesToSync}  -noupdate $servers[0]{pathOfFilesToSync}";
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
				  . "Synced files between $servers[0]{host}/$servers[$server_num]{pathOfFilesToSync}"
				  . " and $servers[$server_num]{host}/$servers[$server_num]{pathOfFilesToSync}\n"
				  . $_;
	
				print $_;
			}
		}
	
		if ($runIdentifier eq "first") {
			if (!exists $servers_to_retry{$server_num})
			{
				#make a time stamp on the hub
				stampServer( 0, $server_num );
	
				#stamp every server with a stamp from a server it has already data from
				for ( my $i = 0 ; $i < $server_num ; $i++ ) {

					  if (!exists $servers_to_retry{$i}) {
					    stampServer( $server_num, $i );
					  }				
				}

			}
	
		} 
		elsif ($runIdentifier eq "firstretry") {
	
			if ($servers[$server_num]{type} ne 'delete')
			{
				#make a time stamp on the hub
				stampServer( 0, $server_num );
	
				#stamp every server with a stamp from a server it has already data from
				for ( my $i = 0 ; $i < $server_num ; $i++ ) {

					   if (!exists $servers_to_retry{$i}) {
					    stampServer( $server_num, $i );
					  }				
				}
			}
	
		}
		elsif ($runIdentifier eq "second") {
			if (!exists $servers_to_retry{$server_num})
			{
				#stamp every server with a stamp of the server it now got the data from
				for ( my $i = $#servers ; $i > $server_num ; $i-- ) {
					stampServer( $server_num, $i );
				}
			}
		}
		elsif ($runIdentifier eq "secondretry") {
			if ($servers[$server_num]{type} ne 'delete')
			{
				#stamp every server with a stamp of the server it now got the data from
				for ( my $i = $#servers ; $i > $server_num ; $i-- ) {
					stampServer( $server_num, $i );
				}
			}
		}
	}
}

sub wrileSyncLog {
	my $write_type		= $_[0];
	my $server_num		= $_[1];
	my $host_to_change	= $_[2];
	my $table			= $_[3];
	my $record_id 		= $_[4];
	my $sql_statement 	= $_[5];
	my $host_id_from 	= 1;
	my $host_id_to 		= 1;
	my $host_num_to		= 0;
	my $host_num_from	= 0;
	my $change_log;
	my $comment;
	my $print_string;
	
	if ($host_to_change ne $servers[$server_num]{host}) {
		$host_id_from = $servers[$server_num]{id};
	}
	
	for my $server_num_loop ( 0 .. $#servers ) {
		if ($host_to_change eq $servers[$server_num_loop]{host}) {
			$host_id_to = $servers[$server_num_loop]{id};
			$host_num_to = $server_num_loop;
		}
		if ($host_id_from == $servers[$server_num_loop]{id}) {
			$host_num_from = $server_num_loop;
		}		
	}	
	
	
	#get details about the user wrote that change
	#The UNION in the Subquery makes sure  there is a date even if the server was never synct before
	$sql = "SELECT  `change_log`.`timestamp` ,
						`change_log`.comment,
						`users`.`id`,
						`users`.`email`,
						`users`.`name`,
						`users`.`lastname`,
						`users`.`user_name`
				FROM `change_log`
				JOIN `users` ON `change_log`.`user_id` = `users`.`id`
				WHERE `table` = '$table'
						AND `record_id` = '$record_id'
						AND `change_log`.`timestamp` > 
							(
							SELECT this_time FROM `sync` WHERE sync_from = ? 
							UNION SELECT '0000-00-00' 
							ORDER BY this_time DESC LIMIT 1
							)
				ORDER BY `change_log`.`timestamp` DESC
				LIMIT 1";

	#see if we have a entry in the change_log
	$print_string= "Get changelog from ".$servers[$host_num_from]{host} . " for writing sync_log\n";
	print $print_string;
	$verboseOutput = $verboseOutput .  $print_string;

	
	my $db = connectToMySQLServer ($host_num_from);
	if (!$db) {
		errorMessage( 'warning', "could not get the changelog from: " . $servers[$host_num_from]{host} . "\n" );
		$change_log->{'comment'} = "unknown";
		$change_log->{'email'} = "unknown";
		$change_log->{'name'} = "unknown";
		$change_log->{'lastname'} = "unknown";
		$change_log->{'user_name'} = "unknown";		
	}
	else {		
		
		$change_log = $db->selectrow_hashref( $sql, undef, $servers[$host_num_to]{id} );
		if ( defined $DBI::errstr ) {
	
			if ($DBI::errstr =~ /.*?Lost connection to MySQL server during query.*?/ or 
				$DBI::errstr =~ /.*?Can\'t connect to MySQL server.*?/ or
				$DBI::errstr =~ /.*?MySQL server has gone away.*?/) {
				
				errorMessage( 'warning', "could not get the changelog from: " . $servers[$host_num_from]{host} . "\n$DBI::errstr\n" );
				$change_log->{'comment'} = "unknown";
				$change_log->{'email'} = "unknown";
				$change_log->{'name'} = "unknown";
				$change_log->{'lastname'} = "unknown";
				$change_log->{'user_name'} = "unknown";
	
			}
			#anything else will lead to an abbort
			else {
			   errorMessage( 'critical', "could not get the changelog from: " . $servers[$host_num_from]{host} . "\n$DBI::errstr\n" );
	
			}	
		}
	
	$db->disconnect;	
	}
		
	my $sql       = "INSERT INTO sync_log (`site_id_from`,`site_id_to`,`table`,`record_id`,`update_type`,`user_id`,`comment`) 
						VALUES (?,?,?,?,?,?,?)";
	
	if ($write_type ne "UPDATE" and $write_type ne "INSERT") {
		errorMessage( 'critical', "the write_type in the writeSyncLog function can just be UPDATE or INSERT\n" );
	}
	
	
	
	$Data::Dumper::Indent = 0;
	$Data::Dumper::Terse = 1;
	#$Data::Dumper::Varname = "sync_info";
 	$comment = Dumper({'user_info'=>$change_log,'sql'=>$sql_statement});
	$dbh[0]->do( $sql, undef, @{[$host_id_from, $host_id_to,$table,$record_id,$write_type,$change_log->{'id'},$comment]});
	if ( defined $DBI::errstr ) {
		errorMessage( 'critical', "could not write sync_log  \n$DBI::errstr\n" );
	}	
	
	
}



sub stampServer {
	my $server_num_to_stamp      = $_[0];
	my $server_num_got_data_from = $_[1];
	my $sql_for_sync_stamp       = "INSERT INTO sync (sync_from,this_time) VALUES (?,NOW())
 			  			  			ON DUPLICATE KEY UPDATE last_time=this_time, this_time=NOW();";

	#we just stamp if the server we supposedly got data from is a master
	#as no server should not get ever data from a slave, we don't stamp server as sync_from a slave
	if ( $servers[$server_num_got_data_from]{'type'} eq 'master' ) {

		my $db = connectToMySQLServer ($server_num_to_stamp);
		if (!$db) {
			errorMessage( 'warning', "could not stamp  " . $servers[$server_num_to_stamp]{host} . "\n" );
	
		}
		else {	
			$db->do( $sql_for_sync_stamp, undef, $servers[$server_num_got_data_from]{'id'} );
			if ( defined $DBI::errstr ) {
				errorMessage( 'warning', "could not stamp  " . $servers[$server_num_to_stamp]{host} . "\n$DBI::errstr\n" );
			}
			$db->disconnect;
		}
	}
}

#$_[0] is the level and can be "warning" or "critical", warning prints the message, critical stops the execution
#$_[1] is the actual error message
sub errorMessage {
	my $level   = $_[0];
	my $message = $_[1];
	my $server_num = $_[2];
	my $print_string;
	
	$errorOutput = $errorOutput . $message;

	if ( $level eq "critical" ) {
		$errorOutput = "CRITICAL ERROR:\n----------------- \n" . $errorOutput . "\n ----------------- STOP execution\n";
		printErrorsAndSummary();
		sendAdministratorEmail();
		die;
	}
	elsif ( $level eq "retry" ) {
		$print_string= "RETRY ERROR:\n" . $message . "\nWe will stop syncing the server " . $servers[$server_num]{host} . " and try later again\n\n";
		$verboseOutput = $verboseOutput .  $print_string;
		print $print_string;
  		if (!exists $servers_to_retry{$server_num})
			{
				print $server_num ." not found\n";
				$verboseOutput = $verboseOutput .  $server_num ." not found\n";
				
  	  			$servers_to_retry{$server_num}=1;
			}

	}
	else {
		print "ERROR:\n " . $message . "\n";
	}
}

sub printErrorsAndSummary {

	if ( $errorOutput ne "" ) {
		print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
		print "ERROR:\n" . $errorOutput;
		print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n";
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
	my $subjectPostfix = "";
	my $verboseOutputFile;

	# try new temporary filenames until we get one that didn't already exist
	do { $verboseOutputFile = tmpnam() } until $verboseOutputFH = IO::File->new( $verboseOutputFile, O_RDWR | O_CREAT | O_EXCL );

	# install atexit-style handler so that when we exit or die,
	# we automatically delete this temporary file

	if ( $errorOutput ne "" ) {
		$administratorEmailData = $errorOutput . "\n";
		$subjectPostfix         = " ERROR!";
	}

	#write verbose informations to file
	print $verboseOutputFH "VERBOSE INFORMATION:\n$verboseOutput\n";
	print $verboseOutputFH "###############################################################################################\n";
	undef $verboseOutputFH;

	$administratorEmailData = $administratorEmailData . $syncSummary . $fileSyncSummary;

	my $msg = MIME::Lite->new(
							   From    => $emailFromAddress,
							   To      => $administratorAddresses,
							   Subject => 'INF personnel database syncronization report!' . $subjectPostfix,
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
	my $server_num   = $_[0];
	
	my $db = DBI->connect( 'DBI:mysql:' . $servers[$server_num]{database} . ';host=' . $servers[$server_num]{host}.';mysql_connect_timeout=5;mysql_read_timeout=1',
					$servers[$server_num]{username},
					$servers[$server_num]{password} );
					
	if ( defined $DBI::errstr ) {
		return 0;
	} else {
		return $db;
	}
	
	
}
