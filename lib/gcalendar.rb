require 'gdata'
require 'nokogiri'
require 'ri_cal'

# = GCalendar
#   A higher level library to access google calendar.  While there are ruby libraries
#   to access various google applications including calendar, none had exactly
#   the featureset I required.  The most critical missing function for me was the
#   ability to handle recurrences properly.
#   
#   I could have taken an existing library and gotten it to handle recurrences, but
#   I also needed to get more experience building libraries, so here it is.
#
#   Requires:
#   gdata: gem install gdata   (for low level http goodness)
#   ri_cal: gem install ri_cal   (for recurrence handling)
#
# = Installation
#  - rake task for database migration
#
# = Examples
# Starting with a valid username/password, create a feed
#   feed = GCalendar::Feed.create(:username=>'user',:password=>'secret')
#
# From there, synchronize the data in the local database with the remote.
#   feed.sync
#
#  Kinds of events we can handle: single event with time range, single event/all day
#  single event spanning multiple days, recurring events, recurring events with
#  exceptions.
#
# Get all events (including the recurring) in the next 30 days
#
# = Other google data or google calendar libs
#  GCal4Ruby
#  http://googlecalendar.rubyforge.org/plugins/doc/
#  http://gcalapi.rubyforge.org/
#  http://github.com/mleone/ruby-gcal/
#  http://github.com/dsisnero/gdata-ruby
#  
# = References
# http://code.google.com/apis/calendar/data/2.0/developers_guide_protocol.html
#
#
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
    def sync_calendars
      xml = get_user_calendar_xml
      self.body = xml.to_s

      # find each entry and display title and links
      xml.css('entry').each { |entry|
        #TODO move this code down into calendar itself.
        existing_cal = calendars.find :first, :conditions=>{ :uid=>entry.css('id').text}
        if existing_cal
          # found existing calendar, check to see if it needs updating
          entry_updated = Time.parse(entry.css('updated').text)
          changed = existing_cal.updated != entry_updated
          if changed
            puts "changed calendar #{existing_cal.title} ar obj = #{existing_cal.updated}  xml = #{entry_updated}"
            if existing_cal.updated > entry_updated
              # local cached is newer than google version
              existing_cal  #.push
              # push it up to google
            else
              # google version is newer than local cached version
              existing_cal.body = entry.to_s  # or existing_cal.pull
              existing_cal.save!
            end
          else
            puts "existing calendar #{existing_cal.title} unchanged"
          end

        else
          cal = Calendar.new(:init=>entry)
          puts "not found.  creating new calendar object for #{cal.title}"
          calendars << cal
        end
      }
      # find any local calendars that are new and push them up to google
      touch :synced_at

      calendars.each { |cal|
        event_xml = get_events_xml(cal.url)
        cal.sync_events(event_xml) # PENDING - different sync types.
        # when getting events xml, do we get all or ask for a range?
      }
    end

    # return a Nokogiri xml object of this feed.  For docs on functions to view and
    # manipulate the xml object, see Nokogiri.  For docs on the format of the
    # Atom xml feed, see the google calendar api docs.
    def xml
      Nokogiri::XML(body)
    end
  end

  class Calendar < ActiveRecord::Base
    set_table_name "gcal_cals"
    has_many :events, :class_name=>'GCalendar::Event', :dependent=>:destroy, :foreign_key=>'gcal_cal_id'
    belongs_to :feed, :class_name=>'GCalendar::Feed', :foreign_key=>'gcal_feed_id'
    #validates_uniqueness_of :title # TODO find out why this isnt working
    
    NEW_CAL_TEMPLATE = "<entry xmlns='http://www.w3.org/2005/Atom' xmlns:gd='http://schemas.google.com/g/2005' xmlns:gCal='http://schemas.google.com/gCal/2005'><gCal:hidden value='false'></gCal:hidden></entry>"

    ALL_FEED            =  "http://www.google.com/calendar/feeds/default/allcalendars/full"
    ALL_OWNS_FEED = "http://www.google.com/calendar/feeds/default/owncalendars/full"

    before_destroy :destroy_gcal

    # pattern to initialize an AR object
    def init=(xml_entry)
      self.uid = xml_entry.css('id').text
      self.etag = xml_entry['etag'].to_s
      self.title = xml_entry.css('title').text
      self.body = xml_entry.to_s
    end

    # pattern to allow initialization of an AR object with data.
    # pass in :opts or :session hash to the new method of the class and
    # it will call the opts= or session= method which will init the object
    # without problems associated with overriding initialize
    def opts=(hash)
      doc = Nokogiri::XML(Calendar::NEW_CAL_TEMPLATE)
      entry = doc.at('entry')

      Nokogiri::XML::Builder.with(entry) do |xml|
        xml.title :type=>'text' do
          xml.text "#{hash[:name]}"
        end
        xml.summary :type=>'text' do
          xml.text "#{hash[:summary]}"
        end if hash[:summary]
        xml['gCal'].timezone :value=>hash[:timezone] do
          xml.text ""
        end if hash[:timezone]
        xml['gCal'].hidden :value=>hash[:hidden] do
          xml.text ""
        end if hash[:hidden]
        xml['gCal'].color :value=>hash[:color] do
          xml.text ""
        end if hash[:color]
      end
      # Note that the timezone value is the long form timezone string used by
      # google data.  This is the olsen format http://en.wikipedia.org/wiki/Zoneinfo
      # used by tzinfo http://tzinfo.rubyforge.org/
      self.body = doc.to_s
    end

    def del_calendar(sess)
      sess.delete(url)
    end

    # This is different from _updated_at_ the magic AR column which is the last
    # time the AR object was written to.
    # updated is the last updated time as determined by the xml data (ie google)
    def updated
      time = xml.xpath('//updated').text
      Time.parse(time)
    end
    
    def url
      doc = Nokogiri::XML(body).css('link[@rel=\'http://schemas.google.com/gCal/2005#eventFeed\']')
      doc.first['href']
    end

    def edit_url
      doc = Nokogiri::XML(body).css('link[@rel=\'edit\']')
      doc.first['href']
    end

    def sync
      action = :create if synced_at.nil?

      case action
      when :create
        response = feed.session.post(GCalendar::Calendar::ALL_OWNS_FEED, body.to_s)
        resp = Nokogiri::XML(response.body)
        self.body= resp.to_s
        init=resp if response.status_code == 201
        touch :synced_at
      end

      true
    end

    def sync_events(event_xml)
      new_events = Event.build_from_xml(event_xml)

      new_events.each do |e|
        # see if the event is in the association already.
        existing_event = events.find_by_uid e.uid
        if existing_event
          # check to see if we need to update up or down
          changed = e.updated != existing_event.updated
          if changed
            puts "e!=existing_event:  #{e.updated} != #{existing_event.updated}"
          end
          puts "existing event #{existing_event.title}.  need to see if changes need to be propogated"
        else
          events << e
        end
      end
      save!
    end

    def xml
      Nokogiri::XML(body)
    end

    LIST_URL = "http://www.google.com/calendar/feeds/default/allcalendars/full"
    # create, list, delete, update, add subscription, update subscription,
    #  deleting subscription, get acl, add user to acl, update user role in acl,
    # remove user from acl
    private
    def destroy_gcal
      response = feed.session.delete(edit_url)
      return true if response.status_code == 200
      return false
    end
  end

  class Event < ActiveRecord::Base
    set_table_name "gcal_events"
    belongs_to :calendar, :class_name=>'GCalendar::Calendar', :foreign_key=>'gcal_cal_id'

    attr_accessor :original_ruby_obj

    before_save :normalize_blank_to_nil

    def self.makeit(feed)
      tpl = "<entry xmlns='http://www.w3.org/2005/Atom' xmlns:gd='http://schemas.google.com/g/2005'>
  <category scheme='http://schemas.google.com/g/2005#kind' term='http://schemas.google.com/g/2005#event'></category>
  <title type='text'>Tennis with Beth</title>
  <content type='text'>Meet for a quick lesson.</content>
  <gd:transparency value='http://schemas.google.com/g/2005#event.opaque'></gd:transparency>
  <gd:eventStatus value='http://schemas.google.com/g/2005#event.confirmed'></gd:eventStatus>
  <gd:where valueString='Rolling Lawn Courts'></gd:where>
  <gd:when startTime='2009-12-17T15:00:00.000Z' endTime='2009-12-17T17:00:00.000Z'></gd:when>
</entry>"
      cal = feed.calendars.last
      url = cal.url
      resp = feed.sess.post(url,tpl)
      resp.body
    end
    def self.delit

    end

    def self.build_from_xml(event_entries)
      rv = []
      event_entries.xpath('//defns:entry', 'defns'=>'http://www.w3.org/2005/Atom').each do |ent|
        e = Event.new
        e.etag = ent['etag']

        #e.title = ent.xpath('defns:title', 'defns'=>'http://www.w3.org/2005/Atom').text
        e.title = ent.css('title').text  # css ignores namespacing
        e.desc = ent.xpath('defns:content', 'defns'=>'http://www.w3.org/2005/Atom').text
        author = ent.xpath('defns:author', 'defns'=>'http://www.w3.org/2005/Atom')
        e.author = "<#{author.css('name').text}> #{author.css('email').text}" if author
        e.uid = ent.xpath('gCal:uid').first['value'].gsub(/@google.com$/,'')
        e.where = ent.xpath('gd:where').text

        if ent.xpath('gd:when').first
          whentag = ent.xpath('gd:when').first
          e.start, e.end = whentag['startTime'],  whentag['endTime']

          if whentag['startTime'].match(/:/) and whentag['endTime'].match(/:/)
            e.all_day = false
          else
            e.all_day = true
          end
          # alarm info is in here too.  Do we care?
          #whentag.xpath('gd:reminder')
        end
        e.original_event = ent.xpath('gd:originalEvent').to_s # means this is an instance of recurring event
        e.original_event = ent.css('originalEvent').to_s
        # @id - event id of original event
        # @href - event feed for original event

        e.recurring = ent.xpath('gd:recurrence').try(:text)
        #ent.xpath('gd:recurrenceException')
        #ent.path('gd:eventStatus').first.attributes  - confirmed, cancelled or tentative

        #*No query parameters: a recurring event is returned as a single entry element, with a gd:recurrence child element. No gd:when elements are returned for the recurring event.
        #*start-min and/or start-max specified: a recurring event is represented as a single entry element, with multiple gd:when elements for each occurrence in the range specified. The gd:recurrence element is also included in the entry.
        #*singleevents=true: recurring events are represented in the same format as single events, with a single entry element per occurrence of the event. Each entry includes a single gd:when element, but does not include the gd:recurrence syntax. It does, however, include a gd:originalEvent element.

        e.body = ent.to_s
        rv << e
      end
      rv
    end

    def category
      calendar.try :title
    end
    def short_time_range
      start_time = self.start.strftime("%H:%M")
      end_time = self.end.strftime("%H:%M")
      "#{start_time} #{end_time}"
    end
    def day_span
      # figure out if we need to display for more than one day. minimum is 1 day
    end
    def original_event_id
      Nokogiri::XML(original_event).root['id']
    end
    # This is different from _updated_at_ the magic AR column which is the last
    # time the AR object was written to.
    # updated is the last updated time as determined by the xml data (ie google)
    def updated
      time = xml.xpath('//updated').text
      Time.parse(time)
    end
    def xml
      Nokogiri::XML(body)
    end
    #    def title=(v)
    #      #TODO all locally cached attributes need to update the xml body for when
    #      # sync needs to update the server
    #    end

    def rical
      if !recurring.blank?
        r = RiCal::parse_string("BEGIN:VEVENT\n"+recurring+"END:VEVENT").first
      end
      r
    end
    def occurrences(range)
      # rical occurrences
      # r.occurrences(options)
      # options= {:starting, :before, :count, :overlapping}
      # r.zulu_occurrence_range  # gives first and last in range of occurrences
      rv = []
      rical.occurrences(:overlapping=>[range.first, range.last]).each { |rical_event|
        # clone this obj, and set the date
        rv << self.clone
        rv.last.start = rical_event.dtstart
        rv.last.end   = rical_event.dtend
        rv.last.original_ruby_obj = self
      }
      rv
    end

    def normalize_blank_to_nil
      %w[title desc author where start end recurring original_event].each do |field|
        if attributes[field].blank?
          write_attribute(field,nil)
        end
      end
    end

  end
end



#GDATA
# file:///usr/lib/ruby/gems/1.8/gems/gdata-1.1.1/doc/index.html
# http://code.google.com/apis/calendar/data/2.0/developers_guide_protocol.html
#
