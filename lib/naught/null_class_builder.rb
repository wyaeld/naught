require 'naught/null_class_builder/conversions_module'

module Naught
  class NullClassBuilder
    # make sure this module exists
    module Commands
    end

    attr_accessor :base_class

    def initialize
      @interface_defined = false
      @base_class        = BasicObject
      @inspect_proc      = ->{ "<null>" }
      @stub_strategy     = :stub_method_returning_nil
      define_basic_methods
    end

    def interface_defined?
      @interface_defined
    end

    def customize(&customization_block)
      return unless customization_block
      customization_module.module_exec(self, &customization_block)
    end

    def customization_module
      @customization_module ||= Module.new
    end

    def null_equivalents
      @null_equivalents ||= [nil]
    end

    def generate_conversions_module(null_class)
      ConversionsModule.new(null_class, null_equivalents)
    end

    def generate_class
      respond_to_any_message unless interface_defined?
      generation_mod    = Module.new
      customization_mod = customization_module # get a local binding
      builder           = self
      @operations.each do |operation|
        operation.call(generation_mod)
      end
      null_class = Class.new(@base_class) do
        const_set :GeneratedMethods, generation_mod
        const_set :Customizations, customization_mod
        const_set :Conversions, builder.generate_conversions_module(self)

        include NullObjectTag
        include generation_mod
        include customization_mod
      end
      class_operations.each do |operation|
        operation.call(null_class)
      end
      null_class
    end

    def method_missing(method_name, *args, &block)
      command_name = command_name_for_method(method_name)
      if Commands.const_defined?(command_name)
        command_class = Commands.const_get(command_name)
        command_class.new(self, *args, &block).call
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private=false)
      command_name = command_name_for_method(method_name)
      Commands.const_defined?(command_name) || super
    rescue NameError
      super
    end

    ############################################################################
    # Builder API
    #
    # See also the contents of lib/naught/null_class_builder/commands
    ############################################################################

    def black_hole
      @stub_strategy = :stub_method_returning_self
    end

    def respond_to_any_message
      defer(prepend: true) do |subject|
        subject.module_eval do
          def respond_to?(*)
            true
          end
        end
        stub_method(subject, :method_missing)
      end
      @interface_defined = true
    end

    def mimic(class_to_mimic, options={})
      include_super = options.fetch(:include_super) { true }
      @base_class   = root_class_of(class_to_mimic)
      @inspect_proc = -> { "<null:#{class_to_mimic}>" }
      defer do |subject|
        methods = class_to_mimic.instance_methods(include_super) -
          Object.instance_methods
        methods.each do |method_name|
          stub_method(subject, method_name)
        end
      end
      @interface_defined = true
    end

    def impersonate(class_to_impersonate, options={})
      mimic(class_to_impersonate, options)
      @base_class = class_to_impersonate
    end

    def traceable
      defer do |subject|
        subject.module_eval do
          attr_reader :__file__, :__line__

          def initialize(options={})
            backtrace = options.fetch(:caller) { Kernel.caller(4) }
            @__file__, line, _ = backtrace[0].split(':')
            @__line__ = line.to_i
          end
         end
      end
    end

    def defer(options={}, &deferred_operation)
      list = options[:class] ? class_operations : operations
      if options[:prepend]
        list.unshift(deferred_operation)
      else
        list << deferred_operation
      end
    end

    def singleton
      defer(class: true) do |subject|
        require 'singleton'
        subject.module_eval do
          include Singleton
          def self.get(*)
            instance
          end

          %w(dup clone).each do |method_name|
            define_method method_name do
              self
            end
          end

        end
      end
    end

    def define_basic_methods
      defer do |subject|
        subject.module_exec(@inspect_proc) do |inspect_proc|
          define_method(:inspect, &inspect_proc)
          def initialize(*)
          end
        end
      end
      defer(class: true) do |subject|
        subject.module_eval do
          class << self
            alias get new
          end
          klass = self
          define_method(:class) { klass }
        end
      end
    end

    private

    def class_operations
      @class_operations ||= []
    end

    def operations
      @operations ||= []
    end

    def stub_method(subject, name)
      send(@stub_strategy, subject, name)
    end

    def stub_method_returning_nil(subject, name)
      subject.module_eval do
        define_method(name) {|*| nil }
      end
    end

    def stub_method_returning_self(subject, name)
      subject.module_eval do
        define_method(name) {|*| self }
      end
    end

    def command_name_for_method(method_name)
      command_name = method_name.to_s.gsub(/(?:^|_)([a-z])/) { $1.upcase }
    end

    def root_class_of(klass)
      if klass.ancestors.include?(Object)
        Object
      else
        BasicObject
      end
    end

  end
end
