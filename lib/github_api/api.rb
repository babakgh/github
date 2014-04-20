# encoding: utf-8

require 'github_api/configuration'
require 'github_api/connection'
require 'github_api/request'
require 'github_api/mime_type'
require 'github_api/rate_limit'
require 'github_api/core_ext/hash'
require 'github_api/core_ext/array'
require 'github_api/null_encoder'

require 'github_api/api/actions'
require 'github_api/api/factory'
require 'github_api/api/arguments'

module Github

  # Core class for api interface operations
  class API
    extend Github::ClassMethods
    include Constants
    include Authorization
    include MimeType
    include Connection
    include Request
    include RateLimit

    attr_reader *Github.configuration.property_names

    attr_accessor *Validations::VALID_API_KEYS

    attr_accessor :current_options

    # Callback to update current configuration options
     class_eval do
       Github.configuration.property_names.each do |key|
         define_method "#{key}=" do |arg|
           self.instance_variable_set("@#{key}", arg)
           self.current_options.merge!({:"#{key}" => arg})
         end
       end
     end

    # Create new API
    #
    # @api public
    def initialize(options={}, &block)
      setup(options)
      yield_or_eval(&block) if block_given?
    end

    def yield_or_eval(&block)
      return unless block
      block.arity > 0 ? yield(self) : self.instance_eval(&block)
    end

    # Configure options and process basic authorization
    #
    # @api private
    def setup(options={})
      options = Github.configuration.fetch.merge(options)
      self.current_options = options
      Github.configuration.property_names.each do |key|
        send("#{key}=", options[key])
      end
      process_basic_auth(options[:basic_auth])
    end

    # Extract login and password from basic_auth parameter
    #
    def process_basic_auth(auth)
      case auth
      when String
        self.login, self.password = auth.split(':', 2)
      when Hash
        self.login    = auth[:login]
        self.password = auth[:password]
      end
    end

    # List of before callbacks
    #
    # @api public
    def self.before_callbacks
      @before_callbacks ||= []
    end

    # List of after callbacks
    #
    # @api public
    def self.after_callbacks
      @after_callbacks ||= []
    end

    # Before request filter
    #
    # @api public
    def self.before_request(callback, params = {})
      before_callbacks << params.merge(callback: callback)
    end

    # After request filter
    #
    # @api public
    def self.after_request(callback, params = {})
      after_callbacks << params.merge(callback: callback)
    end

    def self.inherited(child_class)
      before_callbacks.reverse_each { |callback|
        child_class.before_callbacks.unshift(callback)
      }
      after_callbacks.reverse_each { |callback|
        child_class.after_callbacks.unshift(callback)
      }
    end

    class << self
      attr_reader :root
      alias_method :root?, :root
    end

    def self.root!
      @root = true
    end

    root!

    def self.internal_methods
      api = self
      api = api.superclass until api.root?
      api.public_instance_methods(true)
    end

    # Find all the api methods that are requests
    #
    # @api private
    def self.request_methods
      @request_methods ||= begin
        methods = (public_instance_methods(true) -
                   internal_methods +
                   public_instance_methods(false)).uniq.map(&:to_s)
        Set.new(methods)
      end
    end

    def self.method_added(method_name)
      # Only subclasses matter
      return if self.root?
      # Only public methods are of interest
      return unless request_methods.include?(method_name.to_s)
      # Do not redefine
      return if (@__methods_added ||= []).include?(method_name.to_s)

      with_method = "#{method_name}_with_callback"
      without_method = "#{method_name}_without_callback"

      return if public_method_defined?(with_method)

      [method_name.to_s, with_method, without_method].each do |met|
        @__methods_added << met
      end

      return if public_method_defined?(with_method)

      define_method(with_method) do |*args, &block|
        send(:execute, without_method, *args, &block)
      end
      alias_method without_method, method_name
      alias_method method_name, with_method
    end

    # Filter callbacks based on kind
    #
    # @param [Symbol] kind
    #   one of :before or :after
    #
    # @return [Array[Hash]]
    #
    # @api private
    def filter_callbacks(kind, action_name)
      matched_callbacks = self.class.send("#{kind}_callbacks").select do |callback|
        callback[:only].nil? || callback[:only].include?(action_name)
      end
    end

    # Run all callbacks associated with this action
    #
    # @apram [Symbol] action_name
    #
    # @api private
    def run_callbacks(action_name, &block)
      filter_callbacks(:before, action_name).each { |hook| send hook[:callback] }
      yield if block_given?
      filter_callbacks(:after, action_name).each { |hook| send hook[:callback] }
    end

    # Execute action
    #
    # @param [Symbol] action
    #
    # @api private
    def execute(action, *args, &block)
      action_name = action.to_s.gsub(/_with(out)?_callback$/, '')
      run_callbacks(action_name) do
        send(action, *args, &block)
      end
    end

    # Responds to attribute query or attribute clear
    #
    # @api private
    def method_missing(method_name, *args, &block) # :nodoc:
      case method_name.to_s
      when /^(.*)\?$/
        return !!send($1.to_s)
      when /^clear_(.*)$/
        send("#{$1.to_s}=", nil)
      else
        super
      end
    end

    # Acts as setter and getter for api requests arguments parsing.
    #
    # Returns Arguments instance.
    #
    def arguments(args=(not_set = true), options={}, &block)
      if not_set
        @arguments
      else
        @arguments = Arguments.new(self, options).parse(*args, &block)
      end
    end

    # Scope for passing request required arguments.
    #
    def with(args)
      case args
      when Hash
        set args
      when /.*\/.*/i
        user, repo = args.split('/')
        set :user => user, :repo => repo
      else
        ::Kernel.raise ArgumentError, 'This api does not support passed in arguments'
      end
    end

    # Set an option to a given value
    #
    # @param [String] option
    # @param [Object] value
    # @param [Boolean] ignore_setter
    #
    # @return [self]
    #
    # @api public
    def set(option, value=(not_set=true), ignore_setter=false, &block)
      raise ArgumentError, 'value not set' if block and !not_set
      return self if !not_set and value.nil?

      if not_set
        set_options option
        return self
      end

      if respond_to?("#{option}=") and not ignore_setter
        return __send__("#{option}=", value)
      end

      define_accessors option, value
      self
    end

    # Defines a namespace
    #
    # @param [Array[Symbol]] names
    #   the name for the scope
    #
    # @return [self]
    #
    # @api public
    def self.namespace(*names)
      options = names.last.is_a?(Hash) ? names.pop : {}
      names   = names.map(&:to_sym)
      name    = names.pop
      return if public_method_defined?(name)

      class_name = extract_class_name(name, options)
      define_method(name) do |*args, &block|
        options = args.last.is_a?(Hash) ? args.pop : {}
        API::Factory.new(class_name, current_options.merge(options), &block)
      end
      self
    end

    # Extracts class name from options
    #
    # @return [String]
    #
    # @api private
    def self.extract_class_name(name, options)
      converted  = options.fetch(:full_name, name).to_s
      converted  = converted.split('_').map(&:capitalize).join
      class_name = options.fetch(:root, false) ? '': "#{self.name}::"
      class_name += converted
      class_name
    end

    private

    # Set multiple options
    #
    # @api private
    def set_options(options)
      unless options.respond_to?(:each)
        raise ArgumentError, 'cannot iterate over value'
      end
      options.each { |key, value| set(key, value) }
    end

    # Define setters and getters
    #
    # @api private
    def define_accessors(option, value)
      setter = proc { |val|  set option, val, true }
      getter = proc { value }

      define_singleton_method("#{option}=", setter) if setter
      define_singleton_method(option, getter) if getter
    end

    # Dynamically define a method for setting request option
    #
    # @api private
    def define_singleton_method(method_name, content=Proc.new)
      (class << self; self; end).class_eval do
        undef_method(method_name) if method_defined?(method_name)
        if String === content
          class_eval("def #{method_name}() #{content}; end")
        else
          define_method(method_name, &content)
        end
      end
    end

  end # API
end # Github
