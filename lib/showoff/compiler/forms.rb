# Adds form processing to the compiler
class Showoff::Compiler
  def renderForms(doc)
    # only process slides marked as forms
    return doc unless @options[:form]

    Showoff::Compiler::Form.new(doc, @options[:form]).render!
  end
end

# Represents an individual form object.
# In a separate class so as to not pollute the compiler class.
# @see https://github.com/puppetlabs/showoff/blob/3f43754c84f97be4284bb34f9bc7c42175d45226/lib/showoff.rb#L848-L1022
class Showoff::Compiler::Form
  def initialize(doc, title)
    @doc   = doc
    @title = title
  end

  # Add the form markup to the slide and then render all elements
  #
  # @todo UI elements to translate once i18n is baked in.
  # @todo Someday this should be rearchitected into the markdown renderer.
  #
  # @return [Nokogiri::HTML::DocumentFragment]
  #     The slide DOM with all form elements rendered.
  #
  # @see
  #     https://github.com/puppetlabs/showoff/blob/3f43754c84f97be4284bb34f9bc7c42175d45226/lib/showoff.rb#L849-L878
  def render!
    begin
      tools = Nokogiri::XML::Node.new('div', @doc).add_class('tools')
        @doc.add_child(tools)

      button = Nokogiri::XML::Node.new('input', @doc).add_class('display')
        button.set_attribute('type', 'button')
        button.set_attribute('value', 'forms.display')
        tools.add_child(button)

      submit = Nokogiri::XML::Node.new('input', @doc).add_class('save')
        submit.set_attribute('type', 'submit')
        submit.set_attribute('value', 'forms.save')
        submit.set_attribute('disabled', 'disabled')
        tools.add_child(submit)

      form = Nokogiri::XML::Node.new('form', @doc).add_class('tools')
        form.set_attribute('id', @title)
        form.set_attribute('action', "form/#{@title}")
        form.set_attribute('method', 'POST')
        @doc.add_child(form)

      @doc.children.each do |elem|
        next if elem == form
        elem.parent = form
      end

      @doc.css('p').each do |p|
        if p.text =~ /^(\w*) ?(?:->)? ?(.*)? (\*?)= ?(.*)?$/
          code     = $1
          id       = "#{@title}_#{code}"
          name     = $2.empty? ? code : $2
          required = ! $3.empty?
          rhs      = $4

          p.replace form_element(id, code, name, required, rhs, p.text)
        end
      end

    rescue Exception => e
      @logger.warn "Form parsing failed: #{e.message}"
      @logger.debug "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
    end

    @doc
  end

  # Generates markup for any supported form element type
  #
  # @param id [String]
  #     The HTML ID for the generated markup
  # @param code [String]
  #     The question code; used for indexing
  # @param name [String]
  #     The full text of the question
  # @param required [Boolean]
  #     Whether the rendered element should be marked as required
  # @param rhs [String]
  #     The right hand side of the question specification, if on one line.
  # @param text [String]
  #     The full content of the content, used for recursive multiline calls
  #
  # @return [String]
  #     The HTML markup for all the HTML nodes that the full element renders to.
  #
  # @see
  #     https://github.com/puppetlabs/showoff/blob/3f43754c84f97be4284bb34f9bc7c42175d45226/lib/showoff.rb#L880-L903
  def form_element(id, code, name, required, rhs, text)
    required = required ? 'required' : ''
    str =  "<div class='form element #{required}' id='#{id}' data-name='#{code}'>"
    str << "<label class='question' for='#{id}'>#{name}</label>"
    case rhs
    when /^\[\s+(\d*)\]$$/             # value = [    5]                                     (textarea)
      str << form_element_textarea(id, code, $1)
    when /^___+(?:\[(\d+)\])?$/        # value = ___[50]                                     (text)
      str << form_element_text(id, code, $1)
    when /^\(.?\)/                     # value = (x) option one (=) opt2 () opt3 -> option 3 (radio)
      str << form_element_radio(id, code, rhs.scan(/\((.?)\)\s*([^()]+)\s*/))
    when /^\[.?\]/                     # value = [x] option one [=] opt2 [] opt3 -> option 3 (checkboxes)
      str << form_element_checkboxes(id, code, rhs.scan(/\[(.?)\] ?([^\[\]]+)/))
    when /^\{(.*)\}$/                  # value = {BOS, [SFO], (NYC)}                         (select shorthand)
      str << form_element_select(id, code, rhs.scan(/[(\[]?\w+[)\]]?/))
    when /^\{$/                        # value = {                                           (select)
      str << form_element_select_multiline(id, code, text)
    when ''                            # value =                                             (radio/checkbox list)
      str << form_element_multiline(id, code, text)
    else
      @logger.warn "Unmatched form element: #{rhs}"
    end
    str << '</div>'
  end

  def form_element_text(id, code, length)
    "<input type='text' id='#{id}_response' name='#{code}' size='#{length}' />"
  end

  def form_element_textarea(id, code, rows)
    rows = 3 if rows.empty?
    "<textarea id='#{id}_response' name='#{code}' rows='#{rows}'></textarea>"
  end

  def form_element_radio(id, code, items)
    form_element_check_or_radio_set('radio', id, code, items)
  end

  def form_element_checkboxes(id, code, items)
    form_element_check_or_radio_set('checkbox', id, code, items)
  end

  def form_element_select(id, code, items)
    str =  "<select id='#{id}_response' name='#{code}'>"
    str << '<option value="">----</option>'

    items.each do |item|
      if item =~ /\((\w+)\)/
        item     = $1
        selected = 'selected'
      else
        selected = ''
      end
      str << "<option value='#{item}' #{selected}>#{item}</option>"
    end
    str << '</select>'
  end

  def form_element_select_multiline(id, code, text)
    str =  "<select id='#{id}_response' name='#{code}'>"
    str << '<option value="">----</option>'

    text.split("\n")[1..-1].each do |item|
      case item
      when /^   +\((\w+) -> (.+)\),?$/         # (NYC -> New York City)
        str << "<option value='#{$1}' selected>#{$2}</option>"
      when /^   +\[(\w+) -> (.+)\],?$/         # [NYC -> New York City]
        str << "<option value='#{$1}' class='correct'>#{$2}</option>"
      when /^   +(\w+) -> (.+),?$/             # NYC -> New, York City
        str << "<option value='#{$1}'>#{$2}</option>"
      when /^   +\((.+)\)$/                    # (Boston)
        str << "<option value='#{$1}' selected>#{$1}</option>"
      when /^   +\[(.+)\]$/                    # [Boston]
        str << "<option value='#{$1}' class='correct'>#{$1}</option>"
      when /^   +([^\(].+[^\),]),?$/           # Boston
        str << "<option value='#{$1}'>#{$1}</option>"
      end
    end
    str << '</select>'
  end

  def form_element_multiline(id, code, text)
    str = '<ul>'

    text.split("\n")[1..-1].each do |item|
      case item
      when /\((.?)\)\s*(\w+)\s*(?:->\s*(.*)?)?/
        modifier = $1
        type     = 'radio'
        value    = $2
        label    = $3 || $2
      when /\[(.?)\]\s*(\w+)\s*(?:->\s*(.*)?)?/
        modifier = $1
        type     = 'checkbox'
        value    = $2
        label    = $3 || $2
      end

      str << '<li>'
      str << form_element_check_or_radio(type, id, code, value, label, modifier)
      str << '</li>'
    end
    str << '</ul>'
  end

  def form_element_check_or_radio_set(type, id, code, items)
    str = ''
    items.each do |item|
      modifier = item[0]

      if item[1] =~ /^(\w*) -> (.*)$/
        value = $1
        label = $2
      else
        value = label = item[1]
      end

      str << form_element_check_or_radio(type, id, code, value, label, modifier)
    end
    str
  end

  def form_element_check_or_radio(type, id, code, value, label, modifier)
    # yes, value and id are conflated, because this is the id of the parent widget
    checked = form_checked?(modifier)
    classes = form_classes(modifier)

    name = (type == 'checkbox') ? "#{code}[]" : code
    str  =  "<input type='#{type}' name='#{name}' id='#{id}_#{value}' value='#{value}' class='#{classes}' #{checked} />"
    str << "<label for='#{id}_#{value}' class='#{classes}'>#{label}</label>"
  end

  def form_classes(modifier)
    modifier.downcase!
    classes = ['response']
    classes << 'correct' if modifier.include?('=')

    classes.join(' ')
  end

  def form_checked?(modifier)
    modifier.downcase.include?('x') ? "checked='checked'" : ''
  end

end