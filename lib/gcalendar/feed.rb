module GCalendar
  # A feed class is an ActiveRecord object that needs a valid google username and password
  # in order to access the Google API.
  # A feed contains many Calendar s, a calendar contains many Event s
  # The active record Calendar and Event classes are used to cache information that
  # is retrieved from the GData API.  A strong effort to make bi-directional updates work
  # properly.
  class Feed < ActiveRecord::Base
    set_table_name "gcal_feeds"
    has_many :calendars, :class_name=>'GCalendar::Calendar', :foreign_key=>'gcal_feed_id', :dependent=>:destroy

    USER_FEED = "http://www.google.com/calendar/feeds/default/owncalendars/full" # :nodoc:

    # Sessions are opened to the google api using a google username and password.
    # This implemented so that only one session is used per feed.  You probably
    # won't need to use this, but if you do, you can access the session for a feed
    # object by:
    #  feed = GCalendar::Feed.first
    #  feed.login  # assigns session
    #  feed.session  # => returns the GData Session object
    #  feed.session = GCal::Session.new  # if you so chose
    # See also GCalendar::Feed#login.
    #
    # The session is actually from GData.
    # You shouldn't ordinarily need to use this function.
    def session
      @@session ||= []
      if @@session[self.id].nil?
        session = GData::Client::Calendar.new
        token = session.clientlogin(username,password)
        @@session[self.id] = session
      end
      @@session[self.id]
    end
    
    # Assign a value to the session for this object.  note that it is saved in
    # a class instance variable so it only needs to be done once per Feed id.
    # You shouldn't ordinarily need to use this function.
    def session=(val)
      @@session ||= []
      @@session[self.id] = val
    end

    # create a new calendar object for this feed.
    # * name - name or title of the calendar
    # * opts - hash of fields for creating the calendar object.
    #  -
    # TODO, move or add function to the calendars association
    def create_calendar(name, opts={})
      opts[:name] = name

      cal = GCalendar::Calendar.new(:opts=>opts)

      if cal.sync
        calendars << cal
      end
      save
    end

    # Creates a login session for this feed.
    # You shouldn't ordinarily need to use this function.
    def login
      self.session = GData::Client::Calendar.new if session.nil?
      @token = session.clientlogin(username,password)
      true
    end

    # Uses session to get the calendar feed for the user
    def get_user_calendar_xml # :nodoc:
      response = session.get(USER_FEED)
      Nokogiri::XML(response.body)
    end

    # get all
    def get_events_xml(url) # :nodoc:
      response = session.get(url)
      Nokogiri::XML(response.body)
    end

    # logic for syncing the feed with all calendars and associated events of said calendars.
    #
    #  a) data exists in gcal and not in local -> create local objects
    #     - note that deletion of a local event must either immediately delete the google
    #     object, or make note of it locally for the sync process to not recreate an object
    #     that should be deleted.
    #  b) data exists in local but not in gcal -> create gcal objects
    #     - see note for a).   however this case can also be handled by inferring
    #     that someone deleted the google object by seeing the last updated timestamp
    #     on our cached object, and assuming that it's missing from google due to
    #     deletion and not unintentional data loss.
    #  c) data exists in both.  timestamps don't match. -> update older object
    #  d) data exists in both, timestamps match -> do nothing (unless force update flag?)
    #
    def sync_calendars(opts={})
      #opts[:force] = true # ignore updated timestamps and update from google unconditionally
      #opts[:range] = Range(Date-start .. Date-end)
      
      # why does the primary calendar feed change every time?
      feed_xml = get_user_calendar_xml
      xml_ts = Time.zone.parse(feed_xml.xpath('/ns:feed/ns:updated', 'ns'=>'http://www.w3.org/2005/Atom').text)
      self.body = feed_xml.to_s if xml_ts != synced_at

      feed_xml.css('entry').each { |entry|
        existing_cal = calendars.find :first, :conditions=>{ :uid=>entry.css('id').text}
        if existing_cal
          # if force existing_cal.events.destroy_all
          existing_cal.sync_with_xml(entry) # , range - allows calendar to only sync specified range
        else
          cal = Calendar.new(:init=>entry)
          puts "XXX not found.  creating new calendar object for #{cal.title}"
          calendars << cal
          cal.sync_events
        end
      }

      # find any local calendars that are new and push them up to google
      calendars.find(:all, :conditions=>{:synced_at=>nil}).each do |entry|
      end
      self.synced_at = xml_ts
      save
    end

    # return a Nokogiri xml object of this feed.  For docs on functions to view and
    # manipulate the xml object, see Nokogiri.  For docs on the format of the
    # Atom xml feed, see the google calendar api docs.
    def xml
      Nokogiri::XML(body)
    end
    def etag
      xml.xpath('/ns:feed', 'ns'=>'http://www.w3.org/2005/Atom').attribute('etag').text
    end
  end

end


