module Globalize
  module Model

    class MigrationError < StandardError; end
    class UntranslatedMigrationField < MigrationError; end
    class MigrationMissingTranslatedField < MigrationError; end
    class BadMigrationFieldType < MigrationError; end

    module ActiveRecord
      module Translated
        def self.included(base)
          base.extend ActMethods
        end

        module ActMethods
          def translates(*attr_names)
            options = attr_names.extract_options!
            options[:translated_attributes] = attr_names

            # Only set up once per class
            unless included_modules.include? InstanceMethods
              class_inheritable_accessor :globalize_options, :globalize_proxy

              include InstanceMethods
              extend  ClassMethods

              self.globalize_proxy = Globalize::Model::ActiveRecord.create_proxy_class(self)
              has_many(
              :globalize_translations,
              :class_name   => globalize_proxy.name,
              :extend       => Extensions,
              :dependent    => :delete_all,
              :foreign_key  => class_name.foreign_key
              )

              after_save :update_globalize_record              
            end

            self.globalize_options = options
            Globalize::Model::ActiveRecord.define_accessors(self, attr_names)

            # Import any callbacks that have been defined by extensions to Globalize2
            # and run them.
            extend Callbacks
            Callbacks.instance_methods.each {|cb| send cb }
          end
          
          # A validation for locale-scoped uniqueness of translated field.
          # I.e. same values are allowed for different locales, but not for the same locale.
          # Can be used in the model only after "translates" declaration.
          def validates_translated_uniqueness_of(*attr_names)
            configuration = { :case_sensitive => true }
            configuration.update(attr_names.extract_options!)

            validates_each(attr_names,configuration) do |record, attr_name, value|
              # The check for an existing value should be run from a class that
              # isn't abstract. This means working down from the current class
              # (self), to the first non-abstract class. Since classes don't know
              # their subclasses, we have to build the hierarchy between self and
              # the record's class.
              class_hierarchy = [record.class]
              while class_hierarchy.first != self
                class_hierarchy.insert(0, class_hierarchy.first.superclass)
              end

              # Now we can work our way down the tree to the first non-abstract
              # class (which has a database table to query from).
              finder_class = class_hierarchy.detect { |klass| !klass.abstract_class? }
              translation_class = Object.const_get "#{finder_class}Translation"

              column = translation_class.columns_hash[attr_name.to_s]

              if value.nil?
                comparison_operator = "IS ?"
              elsif column.text?
                comparison_operator = "#{connection.case_sensitive_equality_operator} ?"
                value = column.limit ? value.to_s[0, column.limit] : value.to_s
              else
                comparison_operator = "= ?"
              end

              sql_attribute = "#{translation_class.quoted_table_name}.#{connection.quote_column_name(attr_name)}"

              if value.nil? || (configuration[:case_sensitive] || !column.text?)
                condition_sql = "#{sql_attribute} #{comparison_operator}"
                condition_params = [value]
              else
                condition_sql = "LOWER(#{sql_attribute}) #{comparison_operator}"
                condition_params = [value.mb_chars.downcase]
              end

              if scope = configuration[:scope]
                Array(scope).map do |scope_item|
                  scope_value = record.send(scope_item)
                  condition_sql << " AND " << attribute_condition("#{record.class.quoted_table_name}.#{scope_item}", scope_value)
                  condition_params << scope_value
                end
              end

              unless record.new_record?
                condition_sql << " AND #{record.class.quoted_table_name}.#{record.class.primary_key} <> ?"
                condition_params << record.send(:id)
              end
              
              # translation_table."locale" is ALWAYS the scope
              locale_value = locale.to_s
              condition_sql << " AND " << attribute_condition("#{translation_class.quoted_table_name}.locale", locale_value)
              condition_params << locale_value
              
              join = "INNER JOIN #{translation_class.quoted_table_name} ON #{translation_class.table_name}.#{record.class.name.underscore}_id = #{record.class.quoted_table_name}.id"
              find_result = finder_class.find_by_sql( ["SELECT #{record.class.quoted_table_name}.id FROM #{record.class.quoted_table_name} #{join} WHERE #{condition_sql}", *condition_params])
              
              if find_result.size > 0
                record.errors.add(attr_name, :taken, :default => configuration[:message], :value => value)
              end
            end
          end

          def locale=(locale)
            @@locale = locale
          end

          def locale
            (defined?(@@locale) && @@locale) || I18n.locale
          end          
        end

        # Dummy Callbacks module. Extensions to Globalize2 can insert methods into here
        # and they'll be called at the end of the translates class method.
        module Callbacks
        end

        # Extension to the has_many :globalize_translations association
        module Extensions
          def by_locales(locales)
            find :all, :conditions => { :locale => locales.map(&:to_s) }
          end
        end

        module ClassMethods          
          def method_missing(method, *args)
            if method.to_s =~ /^find_by_(\w+)$/ && globalize_options[:translated_attributes].include?($1.to_sym)
              fallbacks = I18n.fallbacks[I18n.locale]
              results = find(:all, :joins => :globalize_translations,
              :conditions => [ "#{i18n_attr($1)} = ? AND #{i18n_attr('locale')} IN (?)",
                args.first,fallbacks.map{|tag| tag.to_s}])
              comp_f = lambda {|x| fallbacks.include?(x) ? fallbacks.index(x) : 99 }
              results.empty? ? nil : results.sort {|x,y| comp_f.call(x.send($1).locale) <=> comp_f.call(y.send($1).locale)}[0]
            else
              super
            end
          end

          def create_translation_table!(fields)
            translated_fields = self.globalize_options[:translated_attributes]
            translated_fields.each do |f|
              raise MigrationMissingTranslatedField, "Missing translated field #{f}" unless fields[f]
            end
            fields.each do |name, type|
              unless translated_fields.member? name 
                raise UntranslatedMigrationField, "Can't migrate untranslated field: #{name}"
              end              
              unless [ :string, :text ].member? type
                raise BadMigrationFieldType, "Bad field type for #{name}, should be :string or :text"
              end 
            end
            self.connection.create_table(translation_table_name) do |t|
              t.references self.table_name.singularize
              t.string :locale
              fields.each do |name, type|
                t.column name, type
              end
              t.timestamps              
            end
            self.connection.add_index translation_table_name, "#{self.table_name.singularize}_id"
          end

          def drop_translation_table!
            self.connection.remove_index translation_table_name, "#{self.table_name.singularize}_id"
            self.connection.drop_table translation_table_name
          end

          def add_translation_table_index(column_name, options = {})
            self.connection.add_index(translation_table_name, column_name, options)
          end

          def remove_translation_table_index(options = {})
            self.connection.remove_index(translation_table_name, options)
          end

          private

          def i18n_attr(attribute_name)
            self.base_class.name.underscore + "_translations.#{attribute_name}"
          end

          def translation_table_name
            self.name.underscore + '_translations'
          end        
        end

        module InstanceMethods
          def reload(options = nil)
            globalize.clear

            # clear all globalized attributes
            # TODO what's the best way to handle this?
            self.class.globalize_options[:translated_attributes].each do |attr|
              @attributes.delete attr.to_s
            end

            super options
          end

          def globalize
            @globalize ||= Adapter.new self
          end

          def update_globalize_record
            globalize.update_translations!
          end

          def translated_locales
            globalize_translations.scoped(:select => 'DISTINCT locale').map {|gt| gt.locale.to_sym }
          end

          def set_translations options
            options.keys.each do |key|

              translation = globalize_translations.find_by_locale(key.to_s) ||
              globalize_translations.build(:locale => key.to_s)
              translation.update_attributes!(options[key])
            end
          end

          def set_translation(attr_name, locale, value)
            set_translations( { locale => {attr_name => value} })
          end

        end
      end
    end
  end
end