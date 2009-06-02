class Test::Unit::TestCase
 
  def self.should_translate(*attributes)
    # TODO: a shoulda helper model_class should be here instead, but it doesn't work for me for some reason
    klass = self.get_model_class
  
    columns = klass.globalize_proxy.columns
    attributes.each do |a|
      should "translate attribute :#{a}" do      
        assert columns.detect {|c| c.name == a.to_s }
      end
    end
  end

  private
  def self.get_model_class
    self.name.gsub(/Test$/, '').constantize
  end
  
end
