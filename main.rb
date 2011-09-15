#!/usr/bin/env ruby
# encoding: UTF-8

require 'rubygems'
require 'gtk2'
require 'cloudapp_api'

SCRN_TIME_FMT = '%d%m%y-%H%M%S'
TMP_DIR = "/tmp"

# patches for cloudapp_api
module CloudApp
	class Account
		attr_reader :subscription_expires_at
	end

	class Drop
		def slug
			url.split(/\//).last
		end

		def self.find(id)
			res = get "http://#{$domain}/#{id}"
			res.ok? ? Drop.new(res) : bad_response(res)
		end

		attr_reader :source
	end

	class Multipart
		def payload
			{
				:headers => {
					"User-Agent"   => "Ruby.CloudApp.API",
					"Content-Type" => "multipart/form-data; boundary=#{boundary}"},
				:body => @body
			}
		end
	end
end

module GloudApp
  class App
  	def initialize
  		@client = CloudApp::Client.new
  		
  		@credentials = load_credentials
  		@client.authenticate(@credentials[:username], @credentials[:password])
  		
  		if not credentials_valid?
        @credentials = request_credentials
        @client.authenticate(@credentials[:username], @credentials[:password])
  		end
  
      if not credentials_valid?
        show_error_dialog("Error", "Authentication failed: #{$!.to_s}")
      end
      
      create_tray
  	end
  	
  	def run!
      @tray.run!
      Gtk.main
  	end
  	
  	def credentials_valid?
      # check whether auth was successful
      begin
        @acc = CloudApp::Account.find
        $domain = @acc.domain.nil? ? 'cl.ly' : @acc.domain
        return true
      rescue
        return false
      end
  	end
  	
  	def load_credentials
      if ARGV.length == 2
        # assume that's username and password in ARGV
        return {:username => ARGV[0], :password => ARGV[1]}
      end
      
      @config_file = File.join(ENV['HOME'], '.cloudapp-cli')
      if File.exists?(@config_file)
        creds = YAML.load_file(@config_file)
        return creds unless creds[:username].nil? or creds[:password].nil?
      end
      
      request_credentails
  	end
  	
  	def request_credentials
      login_dlg = LoginDialog.new
      case login_dlg.run
      when Gtk::Dialog::RESPONSE_ACCEPT
        creds = {:username => login_dlg.login.text, :password => login_dlg.password.text}
        login_dlg.destroy
        return creds
      when Gtk::Dialog::RESPONSE_REJECT
        login_dlg.destroy
        return nil
      end
  	end
  	
  	def create_tray
      @tray = Tray.new :default => Proc.new { take_screenshot }
      
      # take and upload screenshot
      @tray.add_action("Take screenshot") { take_screenshot }
      
      # upload file from path in clipboard
      @tray.add_action "Upload from clipboard", 
        :show => Proc.new { |item| check_clipboard(item) },
        :action => Proc.new { upload_from_clipboard }
        
      # upload file via file chooser
      @tray.add_action("Upload file") { upload_via_chooser }
     
      # show about dialog
      @tray.add_action("About") { GloudApp::AboutDialog.run! }
      
      # quit app
      @tray.add_action("Quit", :after_seperator => true) { Gtk.main_quit }
  	end
  	
  	def check_clipboard(item)
      Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD).request_text do |clipboard, text|
        if !text.nil? and File.file?(text)
          item.set_sensitive(true)
          item.label = "Upload: #{text}"
        else
          item.set_sensitive(false)
          item.label = "Upload from clipboard"
        end
      end
  	end
  	
  	def upload_from_clipboard
      Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD).request_text do |clipboard, text|
        if !text.nil? and File.file?(text)
          puts "Uploading file from clipboard..."
          upload_file(text)
        else
          ErrorDialog.run!("Error", "Error uploading file #{file}.")
        end
      end
  	end
  	
  	def upload_via_chooser
      file_dlg = Gtk::FileChooserDialog.new(
        "Upload File", nil, Gtk::FileChooser::ACTION_OPEN, nil,
        [Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_CANCEL],
        ["Upload", Gtk::Dialog::RESPONSE_ACCEPT])
      if file_dlg.run == Gtk::Dialog::RESPONSE_ACCEPT
        file = GLib.filename_to_utf8(file_dlg.filename)
        file_dlg.destroy
        if File.file?(file)
          upload_file(file)
        else
          ErrorDialog.run!("Error", "Error uploading file #{file}.")
        end
      else
        file_dlg.destroy
      end
  	end
  	
  	def upload_file(file)
  		puts "Uploading #{file}"
  		drop = @client.upload(file)
  		puts "URL (in clipboard, too): #{drop.url}"
  		# copy URL to clipboard
  		cb = Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD)
  		cb.text = drop.url
  	end
  	
  	def take_screenshot
  		file = File.join(TMP_DIR, "Screenshot #{Time.now.strftime(SCRN_TIME_FMT)}.png")
  		puts "Taking screenshot..."
  		# TODO: find rubish way to take screen shots
  		# make screenshot via image magick:
  		system("import -window root \"#{file}\"")
  		if File.file?(file)
  			upload_file(file)
  		else
  			ErrorDialog.run!("Error", "Error taking screenshot - did you install imagemagick?")
  		end
  	end
  end
  
  class Tray
    def initialize(options = {}, &default)
      @options = {:tooltip => 'GloudApp', :icon => 'gloudapp.png'}.merge(options)
      @options[:default] = default unless @options[:default].is_a?(Proc)
    end
    
    def add_action(title, options = {}, &proc)
      @actions ||= []
      options = {} unless options.is_a?(Hash)
      options[:action] = proc unless options[:action].is_a?(Proc)
      options[:title] = title unless options[:title].is_a?(String)
      @actions << options
    end
    
    def run!
      @si = Gtk::StatusIcon.new
      @si.pixbuf = Gdk::Pixbuf.new(@options[:icon])
      @si.tooltip = @options[:tooltip]
      @si.signal_connect('activate') do
        @options[:default].call if @options[:default].is_a?(Proc)
      end
      
      create_menu
      @si.signal_connect('popup-menu') do |tray, button, time|
        @actions.each do |action|
          if action[:show].is_a?(Proc)
            action[:show].call(action[:item])
          end
        end
        @menu.popup(nil, nil, button, time)
      end
    end
    
    private
    def create_menu
      @menu = Gtk::Menu.new
      @actions.each do |action|
        @menu.append Gtk::SeparatorMenuItem.new if action[:after_seperator]
        
        item = Gtk::MenuItem.new action[:title].to_s
        action[:item] = item
        item.signal_connect('activate') do
          action[:action].call if action[:action].is_a?(Proc)
        end
        @menu.append item
      end
      @menu.show_all
    end
  end
  
  class ErrorDialog
    def self.run!(title, message)
      err_dlg = Gtk::MessageDialog.new(
        nil, Gtk::Dialog::MODAL, Gtk::MessageDialog::ERROR,
        Gtk::MessageDialog::BUTTONS_CLOSE, message)
      err_dlg.title = title
      err_dlg.icon = Gdk::Pixbuf.new('gloudapp.png')
      err_dlg.run
      err_dlg.destroy
    end
  end
  
  class AboutDialog < Gtk::AboutDialog
    def initialize
      super
      self.icon = Gdk::Pixbuf.new('gloudapp.png')
      self.name = "GloudApp"
      self.program_name = "GloudApp"
      self.version = "0.1"
      self.copyright = "Copyright 2011 Christian Nicolai"
      self.license = "" # TODO: license
      self.artists = ["Jan Graichen"]
      self.authors = ["Christian Nicolai", "Jan Graichen"]
      self.website = "https://github.com/cmur2/gloudapp"
      self.logo = Gdk::Pixbuf.new('gloudapp.png')
    end
    
    def self.run!
      instance = self.new
      instance.run
      instance.destroy
    end
  end
  
  class LoginDialog < Gtk::Dialog
  	attr_reader :login, :password
  
  	def initialize
  		super("Authentication", nil, Gtk::Dialog::MODAL,
  			["Login", Gtk::Dialog::RESPONSE_ACCEPT],
  			[Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_REJECT])
  		self.icon = Gdk::Pixbuf.new('gloudapp.png')
  		self.has_separator = false
  
  		@login = Gtk::Entry.new
  		@password = Gtk::Entry.new.set_visibility(false)
  		image = Gtk::Image.new(Gtk::Stock::DIALOG_AUTHENTICATION, Gtk::IconSize::DIALOG)
  
  		table = Gtk::Table.new(2, 3).set_border_width(5)
  		table.attach(image, 0, 1, 0, 2, nil, nil, 10, 10)
  		table.attach_defaults(Gtk::Label.new("Username:").set_xalign(1).set_xpad(5), 1, 2, 0, 1)
  		table.attach_defaults(@login, 2, 3, 0, 1)
  		table.attach_defaults(Gtk::Label.new("Password:").set_xalign(1).set_xpad(5), 1, 2, 1, 2)
  		table.attach_defaults(@password, 2, 3, 1, 2)
  
  		self.vbox.add(table)
  		self.show_all
  		# close dialog on return or enter
  		self.signal_connect("key_release_event") do |obj, ev|
  			if ev.keyval == Gdk::Keyval::GDK_Return or ev.keyval == Gdk::Keyval::GDK_KP_Enter
  				obj.response(Gtk::Dialog::RESPONSE_ACCEPT)
  			end
  		end
  	end
  end
end

GloudApp::App.new.run!
