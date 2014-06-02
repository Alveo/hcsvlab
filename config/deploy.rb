$: << File.expand_path('./lib', ENV['rvm_path'])
require 'bundler/capistrano'
require 'capistrano/ext/multistage'
require 'capistrano_colors'
require 'rvm/capistrano'
require 'deploy/create_deployment_record'

set :shared_file_dir, "files"
set(:shared_file_path) { File.join(shared_path, shared_file_dir) }

set :keep_releases, 5
set :application, 'hcsvlab-web'
set :stages, %w(qa qa2 staging staging2 production)
set :default_stage, "qa"
set :rpms, "openssl openssl-devel curl-devel httpd-devel apr-devel apr-util-devel zlib zlib-devel libxml2 libxml2-devel libxslt libxslt-devel libffi mod_ssl mod_xsendfile"
set :shared_children, shared_children + %w(log_archive)
set :shell, '/bin/bash'
set :rvm_ruby_string, 'ruby-2.0.0-p0@hcsvlab'
set :rvm_type, :user

# Deploy using copy for now
set :scm, 'git'
# Uncomment to enable Jetty submodule
#set :git_enable_submodules, 1
set :repository, 'git@github.com:IntersectAustralia/hcsvlab.git'
set :deploy_via, :copy
set :copy_exclude, [".git/*", "features/*", "spec/*", "test/*"]

#version tagging
set :branch do
  require 'colorize'
  default_tag = 'HEAD'

  availableLocalBranches = `git branch`.split (/\r?\n/)
  availableLocalBranches.map! { |s|  "(local) " + s.strip}

  availableRemoteBranches = `git branch -r`.split (/\r?\n/)
  availableRemoteBranches.map! { |s|  "(remote) " + s.split('/')[-1].strip}

  puts "Availible tags:".colorize(:yellow)
  puts `git tag`
  puts "Availible branches:".colorize(:yellow)
  availableLocalBranches.each {|s| puts s}
  availableRemoteBranches.each {|s| puts s.colorize(:red)}

  tag = Capistrano::CLI.ui.ask "Tag to deploy (make sure to push the branch/tag first) or HEAD?: [#{default_tag}] ".colorize(:yellow)
  tag = default_tag if tag.empty?
  tag = nil if tag.eql?("HEAD")

  tag
end

set(:user) { "#{defined?(user) ? user : 'devel'}" }
set(:group) { "#{defined?(group) ? group : user}" }
set(:user_home) { "/home/#{user}" }
set(:deploy_to) { "#{user_home}/#{application}" }

default_run_options[:pty] = true

namespace :server_setup do
  task :rpm_install, :roles => :app do
    run "#{try_sudo} yum install -y #{rpms}"
  end
  namespace :filesystem do
    task :dir_perms, :roles => :app do
      run "[[ -d #{deploy_to} ]] || #{try_sudo} mkdir #{deploy_to}"
      run "#{try_sudo} chown -R #{user}.#{group} #{deploy_to}"
      run "#{try_sudo} chmod 0711 #{user_home}"
    end

    task :mkdir_db_dumps, :roles => :app do
      run "#{try_sudo} mkdir -p #{shared_path}/db_dumps"
      run "#{try_sudo} chown -R #{user}.#{group} #{shared_path}/db_dumps"
    end
  end
  namespace :rvm do
    task :trust_rvmrc do
      run "rvm rvmrc trust #{release_path}"
    end
  end
  task :gem_install, :roles => :app do
    run "gem install bundler passenger:4.0.0.rc6"
  end
  task :passenger, :roles => :app do
    run "passenger-install-apache2-module -a"
  end
  namespace :config do
    task :apache do
      src = "#{release_path}/config/httpd/#{stage}_rails_#{application}.conf"
      dest = "/etc/httpd/conf.d/rails_#{application}.conf"
      run "cmp -s #{src} #{dest} > /dev/null; [ $? -ne 0 ] && #{try_sudo} cp #{src} #{dest} && #{try_sudo} /sbin/service httpd graceful; /bin/true"
    end
  end
  namespace :logging do
    task :rotation, :roles => :app do
      src = "#{release_path}/config/#{application}.logrotate"
      dest = "/etc/logrotate.d/#{application}"
      run "cmp -s #{src} #{dest} > /dev/null; [ $? -ne 0 ] && #{try_sudo} cp #{src} #{dest}; /bin/true"
      src = "#{release_path}/config/httpd/httpd.logrotate"
      dest = "/etc/logrotate.d/httpd"
      run "cmp -s #{src} #{dest} > /dev/null; [ $? -ne 0 ] && #{try_sudo} cp #{src} #{dest}; /bin/true"
    end
  end
end
before 'deploy:setup' do
  server_setup.rpm_install
  server_setup.rvm.trust_rvmrc
  server_setup.gem_install
  server_setup.passenger
end
after 'deploy:setup' do
  server_setup.filesystem.dir_perms
  server_setup.filesystem.mkdir_db_dumps
end
after 'deploy:update' do
  server_setup.logging.rotation
  server_setup.config.apache
  deploy.new_secret
  deploy.restart
  deploy.additional_symlinks
  deploy.write_tag
  #deploy.cleanup
  # We need to use our own cleanup task since there is an issue on Capistrano deploy:cleanup task
  #https://github.com/capistrano/capistrano/issues/474
  deploy.customcleanup
end

namespace :deploy do

  desc "Write the tag that was deployed to a file on the server so we can display it on the app"
  task :write_tag do
    branchName = branch.nil? ? "HEAD" : branch

    availableTags = `git tag`.split( /\r?\n/ )
    haveToShowHash = !availableTags.any? { |s| s.include?(branchName) }

    current_deployed_version = branchName
    if (haveToShowHash)
      availableBranches = `git branch -a`.split( /\r?\n/ )
      fullBranchName = ("HEAD".eql?(branchName)) ? branchName : availableBranches.select { |s| s.include?(branchName) }.first.to_s.strip

      #since git marc the current branch with a *, we need to remove that character from the branch name
      fullBranchName.gsub!('*','').strip! if fullBranchName.include?('*')

      current_deployed_version += " (sha1:" + `git rev-parse --short #{fullBranchName}`.strip + ")"
    end

    put current_deployed_version, "#{current_path}/app/views/shared/_tag.html.haml"
  end

  # Passenger specifics: restart by touching the restart.txt file
  task :start, :roles => :app, :except => {:no_release => true} do
    restart
  end
  task :stop do
    ;
  end
  task :restart, :roles => :app, :except => {:no_release => true} do
    run "touch #{File.join(current_path, 'tmp', 'restart.txt')}"
  end

  # Remote bundle install
  task :rebundle do
    run "cd #{current_path} && bundle install"
    restart
  end

  task :bundle_update do
    run "cd #{current_path} && bundle update"
    restart
  end

  desc "Additional Symlinks to shared_path"
  task :additional_symlinks do
    run "rm -rf #{release_path}/tmp/shared_config"
    run "mkdir -p #{shared_path}/env_config"
    run "ln -nfs #{shared_path}/env_config #{release_path}/tmp/env_config"

    run "rm -f #{release_path}/db_dumps"
    run "ln -s #{shared_path}/db_dumps #{release_path}/db_dumps"
  end

  # Load the schema
  desc "Load the schema into the database (WARNING: destructive!)"
  task :schema_load, :roles => :db do
    run("cd #{current_path} && rake db:schema:load", :env => {'RAILS_ENV' => "#{stage}"})
  end

  # Run the sample data populator
  desc "Run the test data populator script to load test data into the db (WARNING: destructive!)"
  task :populate, :roles => :db do
    generate_populate_yml
    run("cd #{current_path} && rake db:populate", :env => {'RAILS_ENV' => "#{stage}"})
  end

  # Seed the db
  desc "Run the seeds script to load seed data into the db (WARNING: destructive!)"
  task :seed, :roles => :db do
    run("cd #{current_path} && rake db:seed", :env => {'RAILS_ENV' => "#{stage}"})
  end

  desc "Full redepoyment, it runs deploy:update and deploy:refresh_db"
  task :full_redeploy do
    update
    rebundle
    refresh_db

    configure_activemq
    configure_fedora
    configure_solr
    configure_tomcat6

  end

  task :configure do
    configure_activemq
    configure_fedora
    configure_solr
    configure_tomcat6
  end

  # Helper task which re-creates the database
  task :refresh_db, :roles => :db do
    require 'colorize'

    # Prompt to refresh_db on unless we're in QA
    if stage.eql?(:qa)
      input = "yes"
    else
      puts "This step (deploy:refresh_db) will erase all data and start from scratch.\nYou probably don't want to do it. Are you sure?' [NO/yes]".colorize(:red)
      input = STDIN.gets.chomp
    end

    if input.match(/^yes/)
      schema_load
      seed
      populate
    else
      puts "Skipping database nuke"
    end
  end

  desc "Safe redeployment"
  task :safe do # TODO roles?
    require 'colorize'
    update
    rebundle

    cat_migrations_output = capture("cd #{current_path} && rake db:cat_pending_migrations 2>&1", :env => {'RAILS_ENV' => stage}).chomp
    puts cat_migrations_output

    if !cat_migrations_output[/^0 pending migration/]
      print "There are pending migrations. Are you sure you want to continue? [NO/yes] ".colorize(:red)
      abort "Exiting because you didn't type 'yes'" unless STDIN.gets.chomp == 'yes'
    end

    backup.db.dump
    backup.db.trim
    migrate
    restart
  end

  desc "Generates new Secret Token"
  task :new_secret, :roles => :app do
    run("cd #{current_path} && rake app:generate_secret", :env => {'RAILS_ENV' => "#{stage}"})
  end

  desc "Start ActiveMQ, Jetty, the A13g workers"
  task :start_services, :roles => :app do
    start_activemq
    #start_jetty
    start_tomcat6
    start_a13g_pollers
  end

  desc "Stop ActiveMQ, Jetty, the A13g workers"
  task :stop_services, :roles => :app do
    stop_a13g_pollers
    #stop_jetty
    stop_tomcat6
    stop_activemq
  end

  desc "Start the jetty server"
  task :start_jetty, :roles => :app do
    run "cd #{current_path} && rake jetty:config", :env => {'RAILS_ENV' => stage}
    run "cd #{current_path} && nohup rake jetty:start > nohup_jetty.out 2>&1", :env => {'RAILS_ENV' => stage}
  end

  desc "Stop the jetty server"
  task :stop_jetty, :roles => :app do
    run "cd #{current_path} && rake jetty:stop", :env => {'RAILS_ENV' => stage}
  end

  desc "Start the Tomcat 6 server"
  task :start_tomcat6, :roles => :app do

    run "cd ${CATALINA_HOME} && nohup bin/startup.sh > nohup_tomcat.out 2>&1", :env => {'RAILS_ENV' => stage}
  end

  desc "Configure Tomcat 6"
  task :configure_tomcat6, :roles => :app do
    run "cp -p #{current_path}/tomcat_conf/setenv.sh $CATALINA_HOME/bin/", :env => {'RAILS_ENV' => stage}
  end

  desc "Configure Fedora"
  task :configure_fedora, :roles => :app do
    run "cp -p #{current_path}/fedora_conf/conf/#{stage}/fedora.fcfg $FEDORA_HOME/server/config/", :env => {'RAILS_ENV' => stage}
  end

  desc "Configure Solr"
  task :configure_solr, :roles => :app do
    run "cp -p #{current_path}/solr_conf/hcsvlab-solr.xml    $CATALINA_HOME/conf/Catalina/localhost/solr.xml", :env => {'RAILS_ENV' => stage}
    run "cp -p #{current_path}/solr_conf/conf/schema.xml     $SOLR_HOME/hcsvlab/solr/hcsvlab-core/conf/schema.xml", :env => {'RAILS_ENV' => stage}
    run "cp -p #{current_path}/solr_conf/conf/solrconfig.xml $SOLR_HOME/hcsvlab/solr/hcsvlab-core/conf/solrconfig.xml", :env => {'RAILS_ENV' => stage}
    run "cp -p #{current_path}/solr_conf/conf/schema.xml     $SOLR_HOME/hcsvlab/solr/hcsvlab-AF-core/conf/schema.xml", :env => {'RAILS_ENV' => stage}
    run "cp -p #{current_path}/solr_conf/conf/solrconfig.xml $SOLR_HOME/hcsvlab/solr/hcsvlab-AF-core/conf/solrconfig.xml", :env => {'RAILS_ENV' => stage}
  end

  desc "Update the HCS vLab Solr core"
  task :update_solr_core, :roles => :app do
    # Remove the existing core and webapp
    run "rm -rf $SOLR_HOME/hcsvlab", :env => {'RAILS_ENV' => stage}
    run "rm -rf $CATALINA_HOME/webapps/solr/", :env => {'RAILS_ENV' => stage}
    create_solr_core
  end

  desc "Create the HCS vLab Solr core"
  task :create_solr_core, :roles => :app do
    # Copy the jar files etc that Tomcat will need for Solr 4.3 logging
    run "cp -rp #{current_path}/solr_conf/lib/ext/* $CATALINA_HOME/lib/", :env => {'RAILS_ENV' => stage}
    # Copy the solr core diir
    run "cp -rp #{current_path}/solr_conf/hcsvlab $SOLR_HOME/", :env => {'RAILS_ENV' => stage}
    # Configure solr
    configure_solr
  end

  desc "Stop the Tomcat 6 server"
  task :stop_tomcat6, :roles => :app do
    run "cd ${CATALINA_HOME} && bin/shutdown.sh", :env => {'RAILS_ENV' => stage}
  end

  desc "Start the a13g pollers"
  task :start_a13g_pollers, :roles => :app do
    run "cd #{current_path} && nohup rake a13g:start_pollers > nohup_a13g_pollers.out 2>&1", :env => {'RAILS_ENV' => stage}
  end

  desc "Stop the a13g pollers"
  task :stop_a13g_pollers, :roles => :app do
    run "cd #{current_path} && rake a13g:stop_pollers", :env => {'RAILS_ENV' => stage}
  end

  desc "Start ActiveMQ"
  task :start_activemq, :roles => :app do
    run "cd $ACTIVEMQ_HOME && nohup bin/activemq start > nohup_activemq.out 2>&1", :env => {'RAILS_ENV' => stage}
  end

  desc "Configure ActiveMQ"
  task :configure_activemq, :roles => :app do
    run "cp -p #{current_path}/activemq_conf/activemq.xml $ACTIVEMQ_HOME/conf/", :env => {'RAILS_ENV' => stage}
  end

  desc "Stop ActiveMQ"
  task :stop_activemq, :roles => :app do
    run "cd $ACTIVEMQ_HOME && bin/activemq stop", :env => {'RAILS_ENV' => stage}
  end

  desc "Restart Galaxy"
  task :restart_galaxy, :roles => :galaxy do
    run "cd $GALAXY_HOME && ./galaxy restart"
  end

  desc "Configure Galaxy"
  task :configure_galaxy, :roles => :galaxy do
    run "sed -i 's+__HCSVLAB_APP_URL__+#{server_url}+g' $GALAXY_HOME/universe_wsgi.ini"
    run "sed -i 's+__GALAXY_PORT__+#{galaxy_port}+g' $GALAXY_HOME/universe_wsgi.ini"
    run "sed -i 's+__TOOL_SHED_URL__+#{galaxy_url + ':' + toolshed_port}+g' $GALAXY_HOME/tool_sheds_conf.xml"
    run "sed -i 's+__HCSVLAB_GA_TRACKER_ID__+#{galaxy_ga_tracker_id}+g' $GALAXY_HOME/universe_wsgi.ini"
    run "sed -i 's+__HCSVLAB_SMTP_SERVER__+#{galaxy_smtp_server}+g' $GALAXY_HOME/universe_wsgi.ini"
  end

  desc "Update galaxy"
  task :update_galaxy, :roles => :galaxy do

    # First show the branches and tags to decide from where are we going to deploy
    require 'colorize'
    default_tag = 'HEAD'
    run "cd $GALAXY_HOME && #{try_sudo} git fetch --all"
    availableLocalBranches = capture("cd $GALAXY_HOME && git branch").split (/\r?\n/)
    availableLocalBranches.map! { |s|  "(local) " + s.strip}

    availableRemoteBranches = capture("cd $GALAXY_HOME && git branch -r").split (/\r?\n/)
    availableRemoteBranches.map! { |s|  "(remote) " + s.split('/')[-1].strip}

    availableTags = capture("cd $GALAXY_HOME && git tag").split (/\r?\n/)

    puts "Availible tags:".colorize(:yellow)
    availableTags.each {|s| puts s}
    puts "Availible branches:".colorize(:yellow)
    availableLocalBranches.each {|s| puts s}
    availableRemoteBranches.each {|s| puts s.colorize(:red)}

    tag = Capistrano::CLI.ui.ask "Tag to deploy (make sure to push the branch/tag first) or HEAD?: [#{default_tag}] ".colorize(:yellow)
    tag = default_tag if tag.empty?

    puts "Deploying brach/tag: #{tag}".colorize(:red)


    # Once we chose the branch/tag, we setup up it in the local repository.
    run "cd $GALAXY_HOME && #{try_sudo} git fetch --all"
    run "cd $GALAXY_HOME && #{try_sudo} git reset --hard #{tag}"

  end

  desc "Redeploy Galaxy, stops, updates, configures and starts galaxy"
  task :redeploy_galaxy, :roles => :galaxy do
    set(:user) { "galaxy" }
    set :default_shell, '/bin/bash'
    update_galaxy
    configure_galaxy
    restart_galaxy
    redeploy_galaxy_toolshed
  end

  desc "Start Galaxy Toolshed"
  task :start_galaxy_toolshed, :roles => :galaxy do
    run "cd $GALAXY_HOME && #{try_sudo} service toolshed start", :env => {'RAILS_ENV' => stage}
  end

  desc "Stop Galaxy Toolshed"
  task :stop_galaxy_toolshed, :roles => :galaxy do
    run "cd $GALAXY_HOME && #{try_sudo} service toolshed stop", :env => {'RAILS_ENV' => stage}
  end

  desc "Configure Galaxy Toolshed"
  task :configure_galaxy_toolshed, :roles => :galaxy do
    toolshed_config = YAML.load_file('config/galaxy_toolshed.yml')[stage.to_s]
    run "sed -i 's+__TOOLSHED_PORT__+#{toolshed_port}+g' $GALAXY_HOME/tool_shed_wsgi.ini"
    run "sed -i 's+__USER__+#{toolshed_config["username"]}+g' $GALAXY_HOME/tool_shed_wsgi.ini"
    run "sed -i 's+__PASSWORD__+#{toolshed_config["password"]}+g' $GALAXY_HOME/tool_shed_wsgi.ini"
    run "sed -i 's+__HOST__+#{toolshed_config["host"]}+g' $GALAXY_HOME/tool_shed_wsgi.ini"
    run "sed -i 's+__DATABASE__+#{toolshed_config["database"]}+g' $GALAXY_HOME/tool_shed_wsgi.ini"
  end

  desc "Redeploy Galaxy toolshed"
  task :redeploy_galaxy_toolshed, :roles => :galaxy do
    set(:user) { "galaxy" }
    set :default_shell, '/bin/bash'
    stop_galaxy_toolshed
    configure_galaxy_toolshed
    start_galaxy_toolshed
  end

  # We need to define our own cleanup task since there is an issue on Capistrano deploy:cleanup task
  #https://github.com/capistrano/capistrano/issues/474
  task :customcleanup, :except => {:no_release => true} do
      count = fetch(:keep_releases, 5).to_i
      run "ls -1dt #{releases_path}/* | tail -n +#{count + 1} | #{try_sudo} xargs rm -rf"
  end

  namespace :shared_file do

    desc <<-DESC
      Generate shared file dirs under shared/files dir and then copies files over.

      For example, given:
        set :shared_files, %w(config/database.yml db/seeds.yml)

      The following directories will be generated:
        shared/files/config/
        shared/files/db/
    DESC

    task :setup, :except => { :no_release => true } do
      if exists?(:shared_files)
        dirs = shared_files.map {|f| File.join(shared_file_path, File.dirname(f)) }
        run "#{try_sudo} mkdir -p #{dirs.join(' ')}"
        run "#{try_sudo} chmod g+w #{dirs.join(' ')}" if fetch(:group_writable, true)
        run "#{try_sudo} chown -R #{user}.#{group} #{dirs.join(' ')}"

        servers = find_servers(:no_release => false)
        servers.each do |server|
          shared_files.each do |file_path|
            top.upload(file_path, File.join(shared_file_path, file_path))
            puts "    Uploaded #{file_path} to #{File.join(shared_file_path, file_path)}"
          end
        end

      end
    end
    after "deploy:setup", "deploy:shared_file:setup"

    desc <<-DESC
      Symlink shared files to release path.

      WARNING: It DOES NOT warn you when shared files not exist.  \
      So symlink will be created even when a shared file does not \
      exist.
    DESC
    task :create_symlink, :except => { :no_release => true } do
      (shared_files || []).each do |path|
        run "ln -nfs #{shared_file_path}/#{path} #{release_path}/#{path}"
      end
    end
    after "deploy:finalize_update", "deploy:shared_file:create_symlink"
  end
end

namespace :backup do
  namespace :db do
    desc "make a database backup"
    task :dump do
      run "cd #{current_path} && rake db:backup", :env => {'RAILS_ENV' => stage}
    end

    desc "trim database backups"
    task :trim do
      run "cd #{current_path} && rake db:trim_backups", :env => {'RAILS_ENV' => stage}
    end
  end
end

desc "Give sample users a custom password"
task :generate_populate_yml, :roles => :app do
  require "yaml"
  require 'colorize'

  puts "Set sample user password? (required on initial deploy) [NO/yes]".colorize(:red)
  input = STDIN.gets.chomp
  do_set_password if input.match(/^yes/)
end

desc "Helper method that actually sets the sample user password"
task :do_set_password, :roles => :app do
  set :custom_sample_password, proc { Capistrano::CLI.password_prompt("Sample User password: ") }
  buffer = Hash[:password => custom_sample_password]
  put YAML::dump(buffer), "#{shared_path}/env_config/sample_password.yml", :mode => 0664
end

after 'multistage:ensure' do
  set(:rails_env) { "#{defined?(rails_env) ? rails_env : stage.to_s}" }
  set :shared_files, %W(
    config/environments/#{stage}.rb
    config/deploy/#{stage}.rb
    config/aaf_rc.yml
    config/broker.yml
    config/database.yml
    config/fedora.yml
    config/hcsvlab-web_config.yml
    config/linguistics.yml
    config/solr.yml)
end
