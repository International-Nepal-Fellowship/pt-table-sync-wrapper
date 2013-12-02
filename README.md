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
	  `site_id` int(3) NOT NULL,
	  `user_id` int(11) NOT NULL COMMENT 'id of the user who changes data',
	  `table` varchar(30) NOT NULL,
	  `record_id` varchar(11) NOT NULL,
	  `update_type` enum('new','update','delete','force delete') NOT NULL,
	  `comment` text,
	  `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
	  PRIMARY KEY (`id`),
	  KEY `change_log_site` (`site_id`),
	  KEY `change_log_user` (`user_id`),
	  KEY `change_log_table` (`table`),
	  KEY `change_log_record` (`record_id`)
	) ENGINE=InnoDB  DEFAULT CHARSET=utf8;
	
This table is needed on every server and the application you run has to write every change into it.

## minimum STRUCTURE for the sync table: ##
	CREATE TABLE `sync` (
	  `sync_from` int(11) unsigned NOT NULL,
	  `sync_to` int(11) NOT NULL,
	  `last_time` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
	  `this_time` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
	  PRIMARY KEY (`sync_from`,`sync_to`)
	) ENGINE=MyISAM DEFAULT CHARSET=utf8;
	
This table is needed on every server. pt-table-sync-wrapper will write into this table which server was synced when


## minimum STRUCTURE for the sync_log table: ##
	CREATE TABLE IF NOT EXISTS `sync_log` (
	  `id` int(11) NOT NULL AUTO_INCREMENT,
	  `site_id_from` int(3) NOT NULL,
	  `site_id_to` int(3) NOT NULL,
	  `user_id` int(11) DEFAULT NULL COMMENT 'id of the user who changes data',
	  `table` varchar(30) NOT NULL,
	  `record_id` varchar(11) NOT NULL,
	  `update_type` enum('INSERT','UPDATE') NOT NULL,
	  `comment` text NOT NULL,
	  `sql` text NOT NULL,
	  `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
	  `time_of_change_on_remote_server` timestamp NULL DEFAULT NULL,
	  `user_email` varchar(100) DEFAULT NULL,
	  `user_firstname` varchar(100) DEFAULT NULL,
	  `user_lastname` varchar(100) DEFAULT NULL,
	  `user_name` varchar(100) DEFAULT NULL,
	  PRIMARY KEY (`id`),
	  KEY `change_log_user` (`user_id`),
	  KEY `change_log_table` (`table`),
	  KEY `change_log_record` (`record_id`),
	  KEY `site_id_from` (`site_id_from`),
	  KEY `site_id_to` (`site_id_to`)
	) ENGINE=InnoDB  DEFAULT CHARSET=utf8;

This table is needed on the hub server, every sync activity will be loged here by pt-table-sync-wrapper

## Changelog ##

###2.3.3 -> 2.4 ###
* more robust by writing detailed sync log
* faster by checking local sync_log table for conflicts instead of checking every remote server
* less locking of the application by running postexecution commands after every sync and not just at the end

###2.3.2 -> 2.3.3 ###
* hides passwords given to pt-table-sync
* more errors are rated as "warnings" instead of "critical"

###2.3.1 -> 2.3.2 ###
* minor bugfix

###2.3 -> 2.3.1 ###
* minor code cleanup

###2.3 -> 2.3 ###
* code cleanup
* clearer messages & better error reporting
* bugfixes

###2.1 -> 2.2 ###
More robust when link goes down during sync
