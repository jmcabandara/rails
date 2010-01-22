require 'active_support/ordered_options'

module Rails
  module SharedConfiguration
    def self.middleware_stack
      @default_middleware_stack ||= ActionDispatch::MiddlewareStack.new.tap do |middleware|
        middleware.use('::ActionDispatch::Static', lambda { Rails.public_path }, :if => lambda { Rails.application.config.serve_static_assets })
        middleware.use('::Rack::Lock', :if => lambda { !ActionController::Base.allow_concurrency })
        middleware.use('::Rack::Runtime')
        middleware.use('::Rails::Rack::Logger')
        middleware.use('::ActionDispatch::ShowExceptions', lambda { ActionController::Base.consider_all_requests_local })
        middleware.use('::ActionDispatch::Callbacks', lambda { !Rails.application.config.cache_classes })
        middleware.use('::ActionDispatch::Cookies')
        middleware.use(lambda { ActionController::Base.session_store }, lambda { ActionController::Base.session_options })
        middleware.use('::ActionDispatch::Flash', :if => lambda { ActionController::Base.session_store })
        middleware.use(lambda { Rails::Rack::Metal.new(Rails.application.config.paths.app.metals.to_a, Rails.application.config.metals) })
        middleware.use('ActionDispatch::ParamsParser')
        middleware.use('::Rack::MethodOverride')
        middleware.use('::ActionDispatch::Head')
      end
    end

    def self.options
      @options ||= Hash.new { |h,k| h[k] = ActiveSupport::OrderedOptions.new }
    end
  end

  # Temporarily separate the plugin configuration class from the main
  # configuration class while this bit is being cleaned up.
  class Railtie::Configuration
    def self.default
      @default ||= new
    end

    attr_reader :middleware

    def initialize
      @options    = SharedConfiguration.options
      @middleware = SharedConfiguration.middleware_stack
    end

    def respond_to?(name)
      super || name.to_s =~ config_key_regexp
    end

  protected

    attr_reader :options

  private

    def method_missing(name, *args, &blk)
      if name.to_s =~ config_key_regexp
        return $2 == '=' ? @options[$1] = args.first : @options[$1]
      end

      super
    end

    def config_key_regexp
      bits = config_keys.map { |n| Regexp.escape(n.to_s) }.join('|')
      /^(#{bits})(?:=)?$/
    end

    # TODO Remove :active_support as special case by adding a railtie
    # for it and for I18n
    def config_keys
      ([:active_support] + Railtie.plugin_names).map { |n| n.to_s }.uniq
    end
  end

  class Engine::Configuration < Railtie::Configuration
    attr_reader   :root
    attr_accessor :eager_load_paths, :load_once_paths, :load_paths

    def initialize(root)
      @root = root
      super()
    end

    def paths
      @paths ||= begin
        paths = Rails::Application::Root.new(@root)
        paths.app                 "app",             :eager_load => true, :glob => "*"
        paths.app.controllers     "app/controllers", :eager_load => true
        paths.app.metals          "app/metal",       :eager_load => true
        paths.app.views           "app/views"
        paths.lib                 "lib",             :load_path => true
        paths.config              "config"
        paths.config.environment  "config/environments", :glob => "#{Rails.env}.rb"
        paths.config.initializers "config/initializers"
        paths.config.locales      "config/locales"
        paths.config.routes       "config/routes.rb"
        paths
      end
    end

    def root=(value)
      @root = paths.path = Pathname.new(value).expand_path
    end

    def eager_load_paths
      @eager_load_paths ||= paths.eager_load
    end

    def load_once_paths
      @eager_load_paths ||= paths.load_once
    end

    def load_paths
      @load_paths ||= paths.load_paths
    end
  end

  class Configuration < Engine::Configuration
    attr_accessor :after_initialize_blocks, :cache_classes, :colorize_logging,
                  :consider_all_requests_local, :dependency_loading, :filter_parameters,
                  :logger, :metals, :plugins,
                  :preload_frameworks, :reload_plugins, :serve_static_assets,
                  :time_zone, :whiny_nils

    attr_writer :cache_store, :controller_paths, :i18n, :log_level

    def initialize(*)
      super
      @after_initialize_blocks      = []
      @filter_parameters            = []
      @dependency_loading           = true
      @serve_static_assets          = true
    end

    def after_initialize(&blk)
      @after_initialize_blocks << blk if blk
    end

    def paths
      @paths ||= begin
        paths = super
        paths.app.controllers.concat(builtin_directories)
        paths.config.database    "config/database.yml"
        paths.log                "log/#{Rails.env}.log"
        paths.tmp                "tmp"
        paths.tmp.cache          "tmp/cache"
        paths.vendor             "vendor",            :load_path => true
        paths.vendor.plugins     "vendor/plugins"

        if File.exists?("#{root}/test/mocks/#{Rails.env}")
          ActiveSupport::Deprecation.warn "\"RAILS_ROOT/test/mocks/#{Rails.env}\" won't be added " <<
            "automatically to load paths anymore in future releases"
          paths.mocks_path  "test/mocks/#{Rails.env}", :load_path => true
        end

        paths
      end
    end

    def frameworks(*args)
      raise "config.frameworks in no longer supported. See the generated " \
            "config/boot.rb for steps on how to limit the frameworks that " \
            "will be loaded"
    end
    alias frameworks= frameworks

    # Enable threaded mode. Allows concurrent requests to controller actions and
    # multiple database connections. Also disables automatic dependency loading
    # after boot, and disables reloading code on every request, as these are
    # fundamentally incompatible with thread safety.
    def threadsafe!
      self.preload_frameworks = true
      self.cache_classes = true
      self.dependency_loading = false

      if respond_to?(:action_controller)
        action_controller.allow_concurrency = true
      end
      self
    end

    # Loads and returns the contents of the #database_configuration_file. The
    # contents of the file are processed via ERB before being sent through
    # YAML::load.
    def database_configuration
      require 'erb'
      YAML::load(ERB.new(IO.read(paths.config.database.to_a.first)).result)
    end

    def view_path=(value)
      ActiveSupport::Deprecation.warn "config.view_path= is deprecated, " <<
        "please do config.paths.app.views= instead", caller
      paths.app.views = value
    end

    def view_path
      ActiveSupport::Deprecation.warn "config.view_path is deprecated, " <<
        "please do config.paths.app.views instead", caller
      paths.app.views.to_a.first
    end

    def routes_configuration_file=(value)
      ActiveSupport::Deprecation.warn "config.routes_configuration_file= is deprecated, " <<
        "please do config.paths.config.routes= instead", caller
      paths.config.routes = value
    end

    def routes_configuration_file
      ActiveSupport::Deprecation.warn "config.routes_configuration_file is deprecated, " <<
        "please do config.paths.config.routes instead", caller
      paths.config.routes.to_a.first
    end

    def database_configuration_file=(value)
      ActiveSupport::Deprecation.warn "config.database_configuration_file= is deprecated, " <<
        "please do config.paths.config.database= instead", caller
      paths.config.database = value
    end

    def database_configuration_file
      ActiveSupport::Deprecation.warn "config.database_configuration_file is deprecated, " <<
        "please do config.paths.config.database instead", caller
      paths.config.database.to_a.first
    end

    def log_path=(value)
      ActiveSupport::Deprecation.warn "config.log_path= is deprecated, " <<
        "please do config.paths.log= instead", caller
      paths.config.log = value
    end

    def log_path
      ActiveSupport::Deprecation.warn "config.log_path is deprecated, " <<
        "please do config.paths.log instead", caller
      paths.config.log.to_a.first
    end

    def controller_paths=(value)
      ActiveSupport::Deprecation.warn "config.controller_paths= is deprecated, " <<
        "please do config.paths.app.controllers= instead", caller
      paths.app.controllers = value
    end

    def controller_paths
      ActiveSupport::Deprecation.warn "config.controller_paths is deprecated, " <<
        "please do config.paths.app.controllers instead", caller
      paths.app.controllers.to_a.uniq
    end

    def cache_store
      @cache_store ||= begin
        if File.exist?("#{root}/tmp/cache/")
          [ :file_store, "#{root}/tmp/cache/" ]
        else
          :memory_store
        end
      end
    end

    # Include builtins only in the development environment.
    def builtin_directories
      Rails.env.development? ? Dir["#{RAILTIES_PATH}/builtin/*/"] : []
    end

    def log_level
      @log_level ||= Rails.env.production? ? :info : :debug
    end

    def time_zone
      @time_zone ||= "UTC"
    end

    def i18n
      @i18n ||= begin
        i18n = ActiveSupport::OrderedOptions.new
        i18n.load_path = []

        if File.exist?(File.join(root, 'config', 'locales'))
          i18n.load_path << Dir[File.join(root, 'config', 'locales', '*.{rb,yml}')]
          i18n.load_path.flatten!
        end

        i18n
      end
    end

    def environment_path
      "#{root}/config/environments/#{Rails.env}.rb"
    end

    # Holds generators configuration:
    #
    #   config.generators do |g|
    #     g.orm             :datamapper, :migration => true
    #     g.template_engine :haml
    #     g.test_framework  :rspec
    #   end
    #
    # If you want to disable color in console, do:
    #
    #   config.generators.colorize_logging = false
    #
    def generators
      @generators ||= Generators.new
      if block_given?
        yield @generators
      else
        @generators
      end
    end

    # Allow Notifications queue to be modified or add subscriptions:
    #
    #   config.notifications.queue = MyNewQueue.new
    #
    #   config.notifications.subscribe /action_dispatch.show_exception/ do |*args|
    #     ExceptionDeliver.deliver_exception(args)
    #   end
    #
    def notifications
      ActiveSupport::Notifications
    end

    class Generators #:nodoc:
      attr_accessor :aliases, :options, :colorize_logging

      def initialize
        @aliases = Hash.new { |h,k| h[k] = {} }
        @options = Hash.new { |h,k| h[k] = {} }
        @colorize_logging = true
      end

      def method_missing(method, *args)
        method = method.to_s.sub(/=$/, '').to_sym

        if method == :rails
          namespace, configuration = :rails, args.shift
        elsif args.first.is_a?(Hash)
          namespace, configuration = method, args.shift
        else
          namespace, configuration = args.shift, args.shift
          @options[:rails][method] = namespace
        end

        if configuration
          aliases = configuration.delete(:aliases)
          @aliases[namespace].merge!(aliases) if aliases
          @options[namespace].merge!(configuration)
        end
      end
    end
  end
end
