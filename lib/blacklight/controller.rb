# -*- encoding : utf-8 -*-
#
# Filters added to this controller apply to all controllers in the hosting application
# as this module is mixed-in to the application controller in the hosting app on installation.
module Blacklight::Controller 

  def self.included(base)
    base.send :include, Blacklight::SearchFields

    base.send :before_filter, :default_html_head # add JS/stylesheet stuff
    # now in application.rb file under config.filter_parameters
    # filter_parameter_logging :password, :password_confirmation 
    base.send :helper_method, :current_user_session, :current_user
    base.send :after_filter, :discard_flash_if_xhr    

    # handle basic authorization exception with #access_denied
    base.send :rescue_from, Blacklight::Exceptions::AccessDenied, :with => :access_denied
    
    base.send :helper_method, [:request_is_for_user_resource?]#, :user_logged_in?]
    
    base.send :layout, :choose_layout

    # extra head content
    base.send :helper_method, :current_or_guest_user
    base.send :helper_method, :guest_user
    base.send :helper_method, :extra_head_content
    base.send :helper_method, :stylesheet_links
    base.send :helper_method, :javascript_includes
    base.send :helper_method, :has_user_authentication_provider?


    # This callback runs when a user first logs in
    base.set_callback :logging_in_user, :before, :transfer_guest_user_actions_to_current_user rescue nil

  end

  def method_missing(meth, *args, &block)
    if meth.to_s == "current_or_guest_user"
      # Add the method
      define_method(meth) { blacklight_current_or_guest_user }

      blacklight_current_or_guest_user
    else
      super
    end
  end


  # if user is logged in, return current_user, else return guest_user
  def current_or_guest_user
    if current_user
      if session[:guest_user_id]
        logging_in
        guest_user.destroy
        session[:guest_user_id] = nil
      end
      current_user
    else
      guest_user
    end
  end

  # find guest_user object associated with the current session,
  # creating one as needed
  def guest_user
    existing_guest_user = User.find_by_id(session[:guest_user_id]) if session[:guest_user_id]

    existing_guest_user || User.find(session[:guest_user_id] = create_guest_user.id)
  end


    # test for exception notifier plugin
    def error
      raise RuntimeError, "Generating a test error..."
    end
    
    #############
    # Display-related methods.
    #############
    
    # before filter to set up our default html HEAD content. Sub-class
    # controllers can over-ride this method, or instead turn off the before_filter
    # if they like. See:
    # http://api.rubyonrails.org/classes/ActionController/Filters/ClassMethods.html
    # for how to turn off a filter in a sub-class and such.
    def default_html_head
 
    end
    
    
    # An array of strings to be added to HTML HEAD section of view.
    # See ApplicationHelper#render_head_content for details.
    def extra_head_content
      @extra_head_content ||= []
    end

    
    # Array, where each element is an array of arguments to
    # Rails stylesheet_link_tag helper. See
    # ApplicationHelper#render_head_content for details.
    def stylesheet_links
      @stylesheet_links ||= []
    end
    
    # Array, where each element is an array of arguments to
    # Rails javascript_include_tag helper. See
    # ApplicationHelper#render_head_content for details.
    def javascript_includes
      @javascript_includes ||= []
    end
    
    protected


    # called (once) when the user logs in, insert any code your application needs
    # to hand off from guest_user to current_user.
    def logging_in
      current_user_searches = current_user.searches.all.collect(&:query_params)
      current_user_bookmarks = current_user.bookmarks.all.collect(&:document_id)

      guest_user.searches.all.reject { |s| current_user_searches.include?(s.query_params)}.each do |s| 
        s.user_id = current_user.id 
        s.save 
      end

      guest_user.bookmarks.all.reject { |b| current_user_bookmarks.include?(b.document_id)}.each do |b| 
        b.user_id = current_user.id 
        b.save
      end
    end

    def create_guest_user
    u = User.create(:email => "guest_#{Time.now.to_i}#{rand(999)}@example.com", :guest => true)
    u.save(:validate => false)
    u
    end



    # Returns a list of Searches from the ids in the user's history.
    def searches_from_history
      session[:history].blank? ? [] : Search.where(:id => session[:history]).order("updated_at desc")
    end
    
    #
    # Controller and view helper for determining if the current url is a request for a user resource
    #
    def request_is_for_user_resource?
      request.env['PATH_INFO'] =~ /\/?users\/?/
    end

    #
    # If a param[:no_layout] is set OR
    # request.env['HTTP_X_REQUESTED_WITH']=='XMLHttpRequest'
    # don't use a layout, otherwise use the "application.html.erb" layout
    #
    def choose_layout
      layout_name unless request.xml_http_request? || ! params[:no_layout].blank?
    end
    
    #over-ride this one locally to change what layout BL controllers use, usually
    #by defining it in your own application_controller.rb
    def layout_name
      'blacklight'
    end

    # Should be provided by authentication provider
    # def current_user
    # end
    # def current_or_guest_user
    # end

    # Here's a stub implementation we'll add if it isn't provided for us
    def blacklight_current_or_guest_user
      current_user if has_user_authentication_provider?
    end

    ##
    # We discard flash messages generated by the xhr requests to avoid
    # confusing UX.
    def discard_flash_if_xhr
      flash.discard if request.xhr?
    end

    ##
    #
    #
    def has_user_authentication_provider?
      respond_to? :current_user
    end           

    def require_user_authentication_provider
      raise ActionController::RoutingError.new('Not Found') unless has_user_authentication_provider?
    end

    ##
    # When a user logs in, transfer any saved searches or bookmarks to the current_user
    def transfer_guest_user_actions_to_current_user
      return unless respond_to? :current_user and respond_to? :guest_user and current_user and guest_user
      current_user_searches = current_user.searches.all.collect(&:query_params)
      current_user_bookmarks = current_user.bookmarks.all.collect(&:document_id)

      guest_user.searches.all.reject { |s| current_user_searches.include?(s.query_params)}.each do |s| 
        s.user_id = current_user.id 
        s.save 
      end

      guest_user.bookmarks.all.reject { |b| current_user_bookmarks.include?(b.document_id)}.each do |b| 
        b.user_id = current_user.id 
        b.save
      end
    end

    ##
    # To handle failed authorization attempts, redirect the user to the 
    # login form and persist the current request uri as a parameter
    def access_denied
      # send the user home if the access was previously denied by the same
      # request to avoid sending the user back to the login page
      #   (e.g. protected page -> logout -> returned to protected page -> home)
      redirect_to root_url and flash.discard and return if request.referer and request.referer.ends_with? request.fullpath

      redirect_to root_url and return unless has_user_authentication_provider?

      redirect_to new_user_session_url(:referer => request.fullpath)
    end
  
end

