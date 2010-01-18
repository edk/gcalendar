module GCalendar

  class Calendar < ActiveRecord::Base
    set_table_name "gcal_cals"
    has_many :events, :class_name=>'GCalendar::Event', :dependent=>:destroy, :foreign_key=>'gcal_cal_id'
    belongs_to :feed, :class_name=>'GCalendar::Feed', :foreign_key=>'gcal_feed_id'
    #validates_uniqueness_of :title # TODO find out why this isnt working
    
    NEW_CAL_TEMPLATE = "<entry xmlns='http://www.w3.org/2005/Atom' xmlns:gd='http://schemas.google.com/g/2005' xmlns:gCal='http://schemas.google.com/gCal/2005'><gCal:hidden value='false'></gCal:hidden></entry>"

    ALL_FEED            =  "http://www.google.com/calendar/feeds/default/allcalendars/full"
    ALL_OWNS_FEED = "http://www.google.com/calendar/feeds/default/owncalendars/full"

    #before_destroy :destroy_gcal  # this can fail if the calendar is the primary calendar

    # given an xml object of a calendar (parsed from the google calendars feed)
    # check to see if the local cached object needs updating, or if the google copy
    # need updating.
    #
    # xml_entry - Nokogiri object of the calendar entry
    # opts - :force -> [true or false] ignore timestamps and force an update from the google side
    #        :range -> A date range to update.  useful for when there is a humungous
    #                       set of events in the calendar.
    def sync_with_xml(xml_entry, opts={})
      # found existing calendar, check to see if it needs updating
      entry_updated = Time.zone.parse(xml_entry.css('updated').text)
      changed = updated != entry_updated
      if changed or opts[:force]==true
        puts "changed calendar #{title} ar obj = #{updated}  xml = #{entry_updated}"
        if updated > entry_updated
          # local cached is newer than google version
          #.push
          # push it up to google
        else
          # google version is newer than local cached version
          init = xml_entry
          save!
        end
      else
        puts "XXX existing calendar #{title} unchanged"
      end
      sync_events(nil, opts)  # run this unconditionally, assuming that changes to events
      # don't change the calendar object.
      #          event_xml = get_events_xml(existing_cal.url)
      #          existing_cal.sync_events(event_xml)
    end

    # xml_entry - Nokogiri object of the calendar entry
    # opts - :force -> [true or false] ignore timestamps and force an update from the google side
    #        :range -> A date range to update.  useful for when there is a humungous
    #                       set of events in the calendar.
    def sync_events(event_xml = nil, opts={})
      if event_xml.nil?
        event_xml = feed.get_events_xml(url)
      end
      # TODO add to build_From_xml  a way to specify a date range
      new_events = Event.build_from_xml(event_xml)

      new_events.each do |e|
        # see if the event is in the calendar association already.
        existing_event = events.find_by_uid e.uid
        if existing_event
          # check to see if we need to update up or down
          changed = e.updated != existing_event.updated
          if changed
            puts "e!=existing_event:  #{e.updated} != #{existing_event.updated}"
          end
          puts "existing event #{existing_event.title}.  need to see if changes need to be propogated"
        else
          puts "adding new event #{e.title}"
          events << e
        end
      end
      save!
    end

    # initialize the AR object from an xml object
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
      Time.zone.parse(time)
    end
    
    def url
      doc = Nokogiri::XML(body).css('link[@rel=\'http://schemas.google.com/gCal/2005#eventFeed\']')
      doc.first['href']
    end

    def edit_url
      doc = Nokogiri::XML(body).css('link[@rel=\'edit\']')
      doc.first['href']
    end

    #    def sync
    #      action = :create if synced_at.nil?
    #
    #      case action
    #      when :create
    #        response = feed.session.post(GCalendar::Calendar::ALL_OWNS_FEED, body.to_s)
    #        resp = Nokogiri::XML(response.body)
    #        self.body= resp.to_s
    #        init=resp if response.status_code == 201
    #        touch :synced_at
    #      end
    #
    #      true
    #    end

    def xml
      Nokogiri::XML(body)
    end

    LIST_URL = "http://www.google.com/calendar/feeds/default/allcalendars/full"
    # create, list, delete, update, add subscription, update subscription,
    #  deleting subscription, get acl, add user to acl, update user role in acl,
    # remove user from acl

    private
    def destroy_gcal
      # TODO is there anything we can use to check if the calendar is primary
      # and avoid deleting it?
      response = feed.session.delete(edit_url)
      return true if response.status_code == 200
      return false
    end
  end

end


