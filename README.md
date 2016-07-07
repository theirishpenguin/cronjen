Cronjen
==================

Copyright &copy; 2016, Declan McGrath, Giuseppe Borgese

Command line tool for using jenkins as a centralized cron server.

OVERVIEW
---------
This project is a simple tool for allowing you to replace individual crontabs,
scattered across several servers, with one centralizing way of managing crons
in jenkins. [Others](https://www.cloudbees.com/blog/drop-cron-use-jenkins-instead-scheduled-jobs)
have outlined the advantages of using jenkins over individual crons so we won't
go into that here.

This project is built on top of the excellent
[Jenkins API Client](https://github.com/arangamani/jenkins_api_client)
project.

This project is in its early days, though should be fully usable, so
please report an issue if there is something it doesn't do right or could be
done better. This is especially true of the installation and setup
process - your feedback on this is appreciated.

FEATURES
---------
Managing lots of scheduled jobs through the Jenkins UI is difficult and cronjen
helps with this. It lets you define cronjobs in files (architected in a
way that is easy to manage in source control) and then install these via
the command line to a jenkin's server as scheduled jobs. These scheduled
jobs then ssh into the target server(s) and run the desired command. You
can then use the the cronjen command line to list the scheduled jobs for
a particular target server in a cron syntax-like manner.

Additionally, as it is a common requirement, cronjen provides the ability to
start/stop AWS EC2 instances. It also allows you to run a command against a
server in "Fire & Forget" mode - this means that one single scheduled job in
Jenkins handles
* the startup of the server
* the running of the command
* waiting for the command to finish
* the stopping of the server

Fire and Forget mode saves you having to manage the lifecycle of the server.

This extra functionality is provided through Cronjen Plus commands.

USAGE
------

### Installation

Clone the cronjen repository from github. There is currently no gem available.

### Pre-requisites
* Your jenkins server will need to be able to ssh into the remote servers you
wish to run jobs on
* Cronjen has been tested against Ruby 2.2.2 and Jenkins 1.644. If you have trouble with
other versions of Ruby or Jenkins please raise an issue.

### Optional Extras
* If you wish to use the EC2 start/stop management functionality of cronjen you
will also need to have the ec2 plugin installed on jenkins and the appropriate
configuration on your AWS account to let jenkins manage the stopping and
starting of servers
* The mailer, timestamper and throttle-concurrents plugins are supported if
they are installed on your jenkins server

### Authentication

As the Jenkins API Client project (upon which cronjen depends) states, "Supplying
credentials to the client is optional, as not all Jenkins instances require
authentication." However, cronjen has only been tested with Jenkins servers that
require username and password authentication. If you would like to see something
else supported please raise an issue.

### Initial Setup
Run the following commands to setup cronjen with your jenkins details

    cd path/to/cronjen # We assume you have cloned down the repo and are under this directory for the rest of this guide
    bundle install
    ./cronjen init # and enter the details you are asked

You can enter any location you like as the cronjen data directory. You may wish
to put it in a location under source control so that you can manage changes to
your crons over time. The location of this directory is configurable and easy
to move around if you change your mind later.

Once you have the questions answered you will have two configuration files
* A private config - this is just for you and lives in the same directory as the
cronjen repo you pulled down
* A project config - this is a config that is useful to be shared across the
team you work on. It does not include details specific to you such as your
jenkins credentials - hence why we have two files.

Note: Even though your config is called a private config, it is not encrypted.
It is only private in the sense that you are not sharing it with others.

### Inventories
Your jenkins server can manage cronjobs for many different target servers.
This grows over time and can become tricky to manage. To help organise this, as
well as allowing us to use the same cron file across multiple servers, we have
borrowed the idea of having an inventory from the ansible project. Cronjen's
inventories are very different from ansible's. They are much simpler and
are in the yaml format.

The inventory file is called inventory.yml and lives under the cronjen data dir
you specified during the initial setup earlier.

The inventory has an entry for every target server you wish to run cronjobs on.
You can call an entry (ie. the key of the entry) anything you like. You will
use the entry key at the command line later to identify the server for which you
wish to manage cronjobs for.

Under this entry key you will have to declare
* target_host_url - must be the URL of the target machine you wish to run a job
on
* cron_filename - we will define crons in individual files in the crons/
directory under the cronjen data dir. Use the name of the cronfile you wish to
install on the server here.

It is recommend to construct the cron_filename by concatenating something that
identifies the type of the server and environment of the server
(eg. myserver-prod). Here is an example of an inventory file...

```
mysql-sandbox:
  target_host_url: db1-sandbox.example.com
  cron_filename: mysql-sandbox

mysql-production:
  target_host_url: db1-prod.example.com
  cron_filename: mysql-prod
```

In summary, you add a new entry to this file whenever you have another server
for which you need to manage the cron.

### Cronfiles
Different crons for different servers will be installed to your jenkins instance and
these are managed in cronfiles underneath the crons/ directory (which in turn lives
under the cronjen data dir you specified during the initial setup earlier).

An example of a cron filename is mysql-sandbox - and as we mentioned before it is
recommended to be the combination of the server type and the server environment.

Note: If the schedule is to be identical for both your server and
production environments you can resuse the same cronfile in both - just give
it a suitably generic name (eg. mysql) and set the cron_filename to be
the same for both of your inventory entries with the same schedule. In
such a case it may make sense to go against the recommendation of including
the server environment in the cronfile's name.

Cronjen's cronfiles do not have the exact same syntax as regular UNIX cronfiles.
Instead they contain more information - 5 columns, with each column being
delimited by the | character

Here is an example of the contents of a cronfile...

```
# Schedule | Timezone | Running User | Unique Name | Command
15 12 * * 1-5 | UTC | peter | Nightly Task | some_command
15 13 * * 1-5 | Europe/Dublin | david | Nightly Task | cd /path/to/some/directory && ./some_script > /path/to/logs/some_script.log 2>&1
00 20 * * *   | UTC | system | Weekly Task 1 (FnF)| CRONJEN_PLUS:{"type":"aws_fire_and_forget","region":"us-west-2", "cmd": "cd /path/to/some/directory && unbuffer ./other_script > /path/to/logs/some_script.log 2>&1 | tee /path/to/logs/other_script.log"}
00 21 * * *   | UTC | system | Weekly Task 2 (Autostart)| CRONJEN_PLUS:{"type":"aws_instance_starter","region":"us-west-2", "cmd": "cd /path/to/some/directory && unbuffer ./other_script_2 > /path/to/logs/some_script_2.log 2>&1 | tee /path/to/logs/other_script_2.log"}
```

The Schedule and the Command columns should be familiar to you from using a UNIX cron. The additional columns are
* Timezone - this is the timezone of the cron entry. You can set the timezone to the timezone of the target server, UTC or whatever you like (eg. "Europe/Dublin", "CET" and so on)
* Running user - this is the name of the UNIX user on the target server that the cronjob will run as. Sometimes you will want to change this to 'root' if elevated permissions are required
* Unique Name - this is a friendly name for the cronjob that makes it easier for us to find the cronjob in the Jenkins UI. For a particular target server, all the cronjobs should have a different Unique Name. If you want to list a command multiple times (eg. for debugging) you can just append something unique to the Unique Name for each line

The last two command examples show the CRONJEN_PLUS syntax in use. The
"aws_fire_and_forget" will start the server run the command and stop it
(the server must already exist in AWS and be in a stopped state). This
can help you reduce your AWS bill :-) You need to set the region as
appropriate.

The "aws_instance_starter" is similar except it does't attempt to stop
the server after the command finishes. This leaves it up to you to
shutdown the server. You can put a "shutdown -h now" in your script that
runs on the server. Or you could choose to leave the server running.

Notes
* The (FnF) and (Autostart) suffixes in the Unique Name is
not mandatory. They are simply presented in the example as useful ways to
highlight certain scheduled jobs as having this special functionality
* The commands "tee" and "unbuffer" in the above cron examples are
useful tools but they can be omitted. If used they must be installed on
your target servers

To install a cronjob on a server you simply type:

    ./cronjen install SOME_INVENTORY_KEY (eg. ./cronjen install mysql-sandbox)

The inventory does the work of figuring out what cron to install on what target server as it ties the target machine and the cronfile together

To list the cronjobs on a server, run the command
```
./cronjen install SOME_INVENTORY_KEY
```

To delete cronjobs from a server, run the command
```
./cronjen clear SOME_INVENTORY_KEY
```

Cronjen Cronjobs in the Jenkins UI
----------------------------------
You will see the the above conventions let us easily find cronjobs of interest on the Jenkins UI. Just a tip - you can run any of these jobs via the Jenkins UI immediately by going into the job and selecting "Build With Parameters". If you want to install a job that can only be triggered manually through the jenkins UI (ie. it is never scheduled to run) then use the schedule "0 5 31 2 *" in your cronfile (there is no such date as the 31st of Feb).

FAQ
---
* What happens to the previous output of a scheduled job when I reinstall crons for a server using cronjen "install"? Answer: It is zapped. When you install the crons to jenkins it deletes the old version of the jobs - so information relating to previous builds is lost
* I just want to update one cron line - can I do this? Answer: No, for a given server all cronjobs are cleared and reinstalled when you run cronjen's "install" command. Of course you will be reinstalling cronjobs for a particular server at a time - so the cronjobs of other servers are not affected.


Documentation that needs to be completed
----------------------------------------
* Configuring plugins
* More info about "cronjen init" questions
* More info about the logger
* More examples

CONTRIBUTING
-------------

If you would like to contribute to this project, just do the following:

1. Fork the repo on Github.
2. Add your features and make commits to your forked repo.
3. Make a pull request to this repo.
4. Review will be done and changes will be requested.
5. Once changes are done or no changes are required, pull request will be merged.
6. The next release will have your changes in it.

BUGS AND FEATURE REQUESTS
-------------------------

Cronjen is still in its early days. It is in use in production however the
internals of the codebase will evolve and we are not committing to any sort of
API at the moment. Rest assured, we won't go out of our way to break things ;-)
If you would like to see a feature implemented we'd like to hear from you.
You can open a feature request under the github issues for cronjen. Likewise
if you see any bugs please open them as an issue. Or if you are based in
Ireland say hello at a Ruby Ireland meetup in person :-) and we can discuss
whatever's on your mind.
