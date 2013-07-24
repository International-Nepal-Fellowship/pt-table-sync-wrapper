# pt-table-sync-wrapper #

## decription ##

This script is written to syncronize the MySQL databases on different servers. It's originally written
to syncronize the personnel database of [INF](http://www.inf.org/ "INF")    
Its written arround pt-table-sync: http://www.percona.com/doc/percona-toolkit (MySQL sync)
and unison: http://www.cis.upenn.edu/~bcpierce/unison/ (file syncs)  

* This script can handle as much servers as you like and can eather sync one or two-way
* the server that runs this script acts as a hub and the other servers as spokes
* for two way sync of more than 2 server the hub sync all server the first time and then goes
around a second time so the changes from the later sync servers also arrive on the earlier sync servers
* Conflicts (changes between two sync on different servers) will be recognized with the help of the "change_log" table
* In a conflict the later change wins but both parties gets an email with the information about the conflict.  
More backgroud information: https://individualit.wordpress.com/2012/07/29/bidirectional-syncing-of-mysql-tables-with-pecona-pt-table-sync/  

### This is not a out-of-the-box solution. It changes your database, so use it just if you understand what it does! 
### I don’t give any guaranty it works. It might destroy your database, server, office. So be careful!

## Autor ##

Artur Neumann at [INF](http://www.inf.org/ "INF")

## minimum STRUCTURE for the change_log table: ##
		
	CREATE TABLE `change_log` (
	  `id` int(11) NOT NULL AUTO_INCREMENT,
	  `user_id` int(11) NOT NULL COMMENT 'id of the user who changes data',
	  `table` varchar(30) NOT NULL,
	  `record_id` varchar(11) NOT NULL,
	  `comment` text NOT NULL,
	  `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
	  PRIMARY KEY (`id`),
	  KEY `change_log_user` (`user_id`),
	  KEY `change_log_table` (`table`),
	  KEY `change_log_record` (`record_id`)
	) ENGINE=InnoDB  DEFAULT CHARSET=utf8;

## Changelog ##
###2.1 -> 2.2 ###
More robust when link goes down during sync

###2.3 -> 2.3 ###
* code cleanup
* clearer messages & better error reporting
* bugfixes

###2.3 -> 2.3.1 ###
* minor code cleanup
