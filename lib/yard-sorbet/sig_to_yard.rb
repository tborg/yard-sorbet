# typed: strict
# frozen_string_literal: true

# Translate sig type syntax to YARD type syntax.
module YARDSorbet::SigToYARD
  extend T::Sig

  IS_LEGACY_RUBY_VERSION = T.let(RUBY_VERSION.start_with?('2.5.'), T::Boolean)

  # @see https://yardoc.org/types.html
  sig { params(node: YARD::Parser::Ruby::AstNode).returns(T::Array[String]) }
  def self.convert(node)
    types = convert_type(node)
    # scrub newlines, as they break the YARD parser
    types.map { |type| type.gsub(/\n\s*/, ' ') }
  end

  sig { params(node: YARD::Parser::Ruby::AstNode).returns(T::Array[String]) }
  def self.convert_type(node)
    children = node.children
    case node.type
    when :aref
      # https://www.rubydoc.info/gems/yard/file/docs/Tags.md#Parametrized_Types
      case children.first.source
      when 'T::Array', 'T::Enumerable', 'T::Range', 'T::Set'
        collection_type = children.first.source.split('::').last
        member_type = convert(children.last.children.first).join(', ')
        ["#{collection_type}<#{member_type}>"]
      when 'T::Hash'
        key_type = convert(children.last.children.first).join(', ')
        value_type = convert(children.last.children.last).join(', ')
        ["Hash{#{key_type} => #{value_type}}"]
      else
        log.info("Unsupported sig aref node #{node.source}")
        [build_generic_type(node)]
      end
    when :arg_paren
      convert(children.first.children.first)
    when :array
      # https://www.rubydoc.info/gems/yard/file/docs/Tags.md#Order-Dependent_Lists
      member_types = children.first.children.map { |n| convert(n) }.join(', ')
      ["Array(#{member_types})"]
    when :call
      if children[0].source == 'T'
        t_method = IS_LEGACY_RUBY_VERSION ? children[1].source : children[2].source
        case t_method
        when 'all', 'attached_class', 'class_of', 'enum', 'noreturn', 'self_type', 'type_parameter', 'untyped'
          # YARD doesn't have equivalent notions, so we just use the raw source
          [node.source]
        when 'any'
          children.last.children.first.children.map { |n| convert(n) }.flatten
        when 'nilable'
          # Order matters here, putting `nil` last results in a more concise
          # return syntax in the UI (superscripted `?`)
          convert(children.last) + ['nil']
        else
          log.warn("Unsupported T method #{node.source}")
          [node.source]
        end
      else
        [node.source]
      end
    when :const_path_ref, :const
      case node.source
      when 'T::Boolean'
        ['Boolean'] # YARD convention for booleans
      else
        [node.source]
      end
    when :hash, :list
      # Fixed hashes as return values are unsupported:
      # https://github.com/lsegal/yard/issues/425
      #
      # Hash key params can be individually documented with `@option`, but
      # sig translation is unsupported.
      ['Hash']
    when :var_ref
      # YARD convention is use singleton objects when applicable:
      # https://www.rubydoc.info/gems/yard/file/docs/Tags.md#Literals
      case node.source
      when 'FalseClass'
        ['false']
      when 'NilClass'
        ['nil']
      when 'TrueClass'
        ['true']
      else
        [node.source]
      end
    when :top_const_ref
      # A top-level constant reference, such as ::Klass
      # It contains a child node of type :const
      convert(children.first)
    else
      log.warn("Unsupported sig #{node.type} node #{node.source}")
      [node.source]
    end
  end

  sig { params(node: YARD::Parser::Ruby::AstNode).returns(String) }
  def self.build_generic_type(node)
    return node.source if node.children.empty? || node.type != :aref

    collection_type = node.children.first.source
    member_type = node.children.last.children
                      .map { |child| build_generic_type(child) }
                      .join(', ')

    "#{collection_type}[#{member_type}]"
  end
end
