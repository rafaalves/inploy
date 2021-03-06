module Inploy
  class Deploy
    include Helper
    include DSL

    attr_accessor :repository, :user, :application, :hosts, :path, :app_folder, :ssh_opts, :branch, :environment,
      :port, :skip_steps, :cache_dirs, :sudo, :login_shell

    define_callbacks :after_setup, :before_restarting_server

    def initialize
      self.server = :passenger
      @cache_dirs = %w(public/cache)
      @branch = 'master'
      @environment = 'production'
      @user = "deploy"
      @path = "/var/local/apps"
      @app_folder = nil
      configure
    end

    def template=(template)
      load_module "templates/#{template}"
    end

    def server=(server)
      load_module "servers/#{server}"
    end

    def configure
      configure_from configuration_file if configuration_file
    end

    def configure_from(file) 
      deploy = self
      eval file.read + ';local_variables.each { |variable| deploy.send "#{variable}=", eval(variable.to_s) rescue nil }'
    end

    def remote_install(opts)
      remote_run "bash < <(wget -O- #{opts[:from]})"
    end

    def remote_setup
      remote_run "cd #{path} && #{@sudo}git clone --depth 1 #{repository} #{application} && cd #{application_folder} #{checkout}#{bundle} && #{@sudo}rake inploy:local:setup RAILS_ENV=#{environment} environment=#{environment}#{skip_steps_cmd}"
    end

    def local_setup
      create_folders 'public', 'tmp/pids', 'db'
      copy_sample_files
      rake "db:create RAILS_ENV=#{environment}"
      run "./init.sh" if file_exists?("init.sh")
      after_update_code
      callback :after_setup
    end

    def remote_update
      remote_run "cd #{application_path} && #{@sudo}rake inploy:local:update RAILS_ENV=#{environment} environment=#{environment}#{skip_steps_cmd}"
    end

    def remote_rake(task)
      remote_run "cd #{application_path} && rake #{task} RAILS_ENV=#{environment}"
    end

    def remote_reset(params)
      remote_run "cd #{application_path} && git reset --hard #{params[:to]}"
    end

    def local_update
      update_code
      after_update_code
    end

    def update_code
      run "git pull origin #{branch}"
    end

    private

    def checkout
      branch.eql?("master") ? "" : "&& $(git branch | grep -vq #{branch}) && git checkout -f -b #{branch} origin/#{branch}"
    end

    def bundle
      " && #{bundle_cmd}" if using_bundler?
    end

    def after_update_code
      run "cd #{path}/#{application} && git submodule update --init && cd #{path}/#{application}/#{app_folder}"
      copy_sample_files
      return unless install_gems
      migrate_database
      update_crontab
      clear_cache
      run "rm -R -f public/assets" if jammit_is_installed?
      rake_if_included "more:parse"
      run "compass compile" if file_exists?("config/initializers/compass.rb")
      rake_if_included "barista:brew"
      rake_if_included "asset:packager:build_all"
      rake_if_included "hoptoad:deploy RAILS_ENV=#{environment} TO=#{environment} REPO=#{repository} REVISION=#{`git log | head -1 | cut -d ' ' -f 2`}"
      ruby_if_exists "vendor/plugins/newrelic_rpm/bin/newrelic_cmd", :params => "deployments"
      callback :before_restarting_server
      restart_server
    end
  end
end
