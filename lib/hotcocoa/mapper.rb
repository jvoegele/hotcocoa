##
# Does most of the heavy lifiting when it comes to HotCocoa mappings.
class HotCocoa::Mappings::Mapper

  class << self
    def map_class klass
      new(klass).include_in_class
    end

    def map_instances_of klass, builder_method, &block
      new(klass).map_method(builder_method, &block)
    end

    ##
    # Borrowed from Active Support.
    def underscore string
      new_string = string.gsub(/::/, '/')
      new_string.gsub!(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      new_string.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
      new_string.tr!("-", "_")
      new_string.downcase!
      new_string
    end

    ##
    # Borrowed from Active Support.
    def camel_case string
      string.to_s.gsub /(?:^|_)(.)/ do $1.upcase end
    end

    attr_reader :bindings_modules
    attr_reader :delegate_modules
  end

  @bindings_modules = {}
  @delegate_modules = {}

  attr_reader :control_class
  attr_reader :builder_method
  attr_reader :control_module
  attr_accessor :map_bindings

  def initialize klass
    @control_class = klass
  end

  def include_in_class
    @extension_method = :include
    customize(@control_class)
  end

  def map_method builder_method, &block
    @extension_method = :extend
    @builder_method   = builder_method

    # the first two lines here seem silly, can we get rid of them?
    mod = (class << self; self; end)
    mod.extend HotCocoa::MappingMethods
    mod.module_eval(&block)

    @control_module = mod
    inst = self # why can't I get rid of this variable and just use self?!?
    HotCocoa.send(:define_method, builder_method) do |*args, &control_block|
      map  = (args.length == 1 ? args[0] : args[1]) || {}
      guid =  args.length == 1 ? nil     : args[0]

      map  = inst.remap_constants(map)
      inst.map_bindings = map.delete(:map_bindings)

      control = inst.respond_to?(:init_with_options) ? inst.init_with_options(inst.control_class.alloc, map) : inst.alloc_with_options(map)

      HotCocoa::Views[guid] = control if guid
      inst.customize(control)
      map.each do |key, value|
        if control.respond_to?("#{key}=")
          control.send("#{key}=", value)

        elsif control.respond_to?(key)
          new_key = (key.start_with?('set') ? key : "set#{key[0].capitalize}#{key[1..-1]}")
          if control.respond_to?(new_key)
            control.send(new_key, value)

          else
            control.send(key)

          end
        elsif control.respond_to?("set#{HotCocoa::Mappings::Mapper.camel_case(key)}")
          control.send("set#{HotCocoa::Mappings::Mapper..camel_case(key)}", value)

        else
          NSLog "Unable to map #{key} as a method"

        end
      end

      if map[:frame].__id__ == CGRectZero.__id__
        control.sizeToFit if control.respondsToSelector(:sizeToFit)
      end

      if control_block
        if inst.respond_to?(:handle_block)
          inst.handle_block(control, &control_block)
        else
          control_block.call(control)
        end
      end
      control
    end

    # make the function callable using HotCocoa.xxxx
    HotCocoa.send(:module_function, builder_method)
    # module_function makes the instance method private, but we want it to stay public
    HotCocoa.send(:public, builder_method)
    self
  end

  ##
  # Returns a hash of constant hashes that were inherited from ancestors
  # that have also been mapped.
  #
  # @return [Hash{Hash}]
  def inherited_constants
    constants = {}
    each_control_ancestor do |ancestor|
      constants.merge!(ancestor.control_module.constants_map)
    end
    constants
  end

  def inherited_delegate_methods
    delegate_methods = {}
    each_control_ancestor do |ancestor|
      delegate_methods.merge!(ancestor.control_module.delegate_map)
    end
    delegate_methods
  end

  def inherited_custom_methods
    methods = []
    each_control_ancestor do |ancestor|
      methods << ancestor.control_module.custom_methods if ancestor.control_module.custom_methods
    end
    methods
  end

  def each_control_ancestor
    control_class.ancestors.reverse.each do |ancestor|
      HotCocoa::Mappings.mappings.values.each do |mapper|
        yield mapper if mapper.control_class == ancestor
      end
    end
  end

  def customize control
    inherited_custom_methods.each do |custom_methods|
      control.send(@extension_method, custom_methods)
    end
    decorate_with_delegate_methods(control)
    decorate_with_bindings_methods(control)
  end

  def decorate_with_delegate_methods control
    control.send(@extension_method, delegate_module_for_control_class)
  end

  def delegate_module_for_control_class
    unless HotCocoa::Mappings::Mapper.delegate_modules.has_key?(control_class)
      delegate_module = Module.new
      required_methods = []
      delegate_methods = inherited_delegate_methods

      if delegate_methods.size > 0
        delegate_methods.each do |delegate_method, mapping|
          required_methods << delegate_method if mapping[:required]
        end

        delegate_methods.each do |delegate_method, mapping|
          parameters = mapping[:parameters] ? (', ' + mapping[:parameters].map {|param| %{"#{param}"} }.join(',')) : ''
          delegate_module.module_eval <<-EOM
            def #{mapping[:to]} &block
              raise "Must pass in a block to use this delegate method" unless block_given?

              @_delegate_builder ||= HotCocoa::DelegateBuilder.new(self, #{required_methods.inspect})
              @_delegate_builder.add_delegated_method(block, "#{delegate_method}" #{parameters})
            end
          EOM
        end

        delegate_module.module_eval <<-EOM
          def delegate_to(object)
            @_delegate_builder ||= HotCocoa::DelegateBuilder.new(self, #{required_methods.inspect})
            @_delegate_builder.delegate_to(object, #{delegate_methods.values.map {|method| ":#{method[:to]}"}.join(', ')})
          end
        EOM
      end

      HotCocoa::Mappings::Mapper.delegate_modules[control_class] = delegate_module
    end

    HotCocoa::Mappings::Mapper.delegate_modules[control_class]
  end


  def decorate_with_bindings_methods(control)
    return if control_class == NSApplication
    control.send(@extension_method, bindings_module_for_control(control)) if @map_bindings
  end

  def bindings_module_for_control(control)
    return HotCocoa::Mappings::Mapper.bindings_modules[control_class] if HotCocoa::Mappings::Mapper.bindings_modules.has_key?(control_class)

    instance = if control == control_class
                 control_class.alloc.init
               else
                 control
               end

    bindings_module = Module.new
    instance.exposedBindings.each do |exposed_binding|
      bindings_module.module_eval <<-EOM
        def #{HotCocoa::Mappings::Mapper.underscore(exposed_binding)}= value
          if value.kind_of?(Hash)
            options = value.delete(:options)
            bind "#{exposed_binding}", toObject:value.keys.first, withKeyPath:value.values.first, options:options
          else
            set#{exposed_binding.capitalize}(value)
          end
        end
      EOM
    end

    HotCocoa::Mappings::Mapper.bindings_modules[control_class] = bindings_module
    bindings_module
  end

  def remap_constants tags
    constants = inherited_constants
    if control_module.defaults
      control_module.defaults.each do |key, value|
        tags[key] = value unless tags.has_key?(key)
      end
    end

    result = {}
    tags.each do |tag, value|
      if constants[tag]
        result[tag] = value.kind_of?(Array) ? value.inject(0) { |a, i| a | constants[tag][i] } : constants[tag][value]
      else
        result[tag] = value
      end
    end
    result
  end

end
