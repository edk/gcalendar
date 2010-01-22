module GCalendar

  class Event < ActiveRecord::Base
    set_table_name "gcal_events"
    belongs_to :calendar, :class_name=>'GCalendar::Calendar', :foreign_key=>'gcal_cal_id'

    named_scope :active, :conditions=>['status=? or status=?','event.confirmed', 'event.tentative']
    named_scope :single_event, :conditions=>['recurring is null and original_event is null']
    named_scope :multiple_event, :conditions=>['recurring is not null or original_event is not null']
    named_scope :date_range, lambda { |range|
      {:conditions=>['start between ? and ?', range.first, range.last]}
    } # only works for single_event


    # used when dealing with multiple events as part of a recurrence.
    # See #occurances for how this gets generated
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

    def self.events_from_xml(feed, event_entries)
      # implementation note:
      # Some of the atom entries are links to other xml objects.  we try to simplify
      # things by following links where necessary, and "flattening" the data by pulling
      # in the referenced data into the current object to avoid having to follow links to
      # multiple objects later.
      #
      rv = []
      event_entries.xpath('//defns:entry', 'defns'=>'http://www.w3.org/2005/Atom').each do |ent|
        e = Event.new
        e.etag = ent['etag']

        e.title = ent.xpath('defns:title', 'defns'=>'http://www.w3.org/2005/Atom').text
        e.desc = ent.xpath('defns:content', 'defns'=>'http://www.w3.org/2005/Atom').text
        author = ent.xpath('defns:author', 'defns'=>'http://www.w3.org/2005/Atom')
        e.author = "<#{author.css('name').text}> #{author.css('email').text}" if author
        e.uid = ent.xpath('gCal:uid').first['value'].gsub(/@google.com$/,'')
        e.where = ent.xpath('gd:where').text
        event_status = ent.xpath('gd:eventStatus')
        if event_status.size > 0

          e.status = event_status.first.attribute('value').to_s.split('#').last  # confirmed, cancelled or tentative from google
          # can also use it as a deleted flag if we want to delete locally and remove from api when doing a sync
        end

        puts "number of gd:when is more than one.  #{ent.xpath('gd:when').to_s}" if ent.xpath('gd:when').size > 1
        if ent.xpath('gd:when').first
          whentag = ent.xpath('gd:when').first
          puts "parsing event whentag = #{whentag.to_s}"
          e.start, e.end = whentag['startTime'],  whentag['endTime']

          # assume that if the datetime string does not have a : character, we only have the date, no time
          # ie. all day event.  all day events can also be specified by the time range 00:00:00 -> 24:00:00 ?
          e.all_day = !(whentag['startTime'].match(/:/) and whentag['endTime'].match(/:/))
          # alarm info is in here too.  Do we care?  whentag.xpath('gd:reminder')
        end

        e.recurring = ent.xpath('gd:recurrence').try(:text)
        puts "recurrence exception!!!! handle it (#{ent.xpath('gd:recurrenceException').to_s})" if ent.xpath('gd:recurrenceException').to_s.size>0
        #ent.path('gd:eventStatus').first.attributes  -
        if false #recurrenceException
          # get the href, create a new nokogiri xml obj
          # use that new one to populate this object.
        end

        e.original_event = ent.xpath('gd:originalEvent')
        if e.original_event && e.original_event.size>0
          orig_event = feed.session.get(e.original_event.first.attributes['href'].to_s)
          orig_xml = Nokogiri::XML(orig_event.body)
          e.recurring = orig_xml.xpath('//gd:recurrence').try :text

          e.original_event = e.original_event.first.to_s  # assume only one original event, unless told otherwise

          # we have a recurrence.  get the original event? copy the recurrence into this
          # object?  make sure to handle recurrence exceptions.
        end

        #*No query parameters: a recurring event is returned as a single entry element, with a gd:recurrence child element. No gd:when elements are returned for the recurring event.
        #*start-min and/or start-max specified: a recurring event is represented as a single entry element, with multiple gd:when elements for each occurrence in the range specified. The gd:recurrence element is also included in the entry.
        #*singleevents=true: recurring events are represented in the same format as single events, with a single entry element per occurrence of the event. Each entry includes a single gd:when element, but does not include the gd:recurrence syntax. It does, however, include a gd:originalEvent element.

        e.body = ent.to_s
        rv << e
      end
      rv
    end

    def update_if_needed(e)
      # check to see if we need to update up or down
      changed = e.updated != updated
      if changed
        if etag != e.etag && (updated > e.updated)
          # local is newer than google version of event
          puts "----------local version is newer.  updating google version"
          puts "L: #{xml.xpath('//title').to_s} \n"+
            "R:  #{e.xml.xpath('//title').to_s} \n"+
            "L: #{xml.xpath('//originalEvent').to_s} \n" +
            "R: #{e.xml.xpath('//originalEvent').to_s} \n" +
            "L: #{xml.xpath('//updated').to_s} \n" +
            "R: #{e.xml.xpath('//updated').to_s} \n" +
            "L: #{xml.xpath('//edited').to_s} \n" +
            "R: #{e.xml.xpath('//edited').to_s} \n" +
            "L: #{xml.xpath('/entry/when').to_s}\n" +
            "R: #{e.xml.xpath('/entry/when').to_s}\n"+
            "L: #{xml.xpath('/entry/eventStatus').to_s}\n" +
            "R: #{e.xml.xpath('/entry/eventStatus').to_s}\n"#+
          #            "R: #{xml.to_s}\n\n" +
          #            "R: #{e.xml.to_s}\n\n"
        else
          # google version is newer than local cached version
          puts "google version is newer.  updating local event #{e.title}"
          update_from(e)
        end
      end
    end

    def category
      @category ||= calendar.title.gsub(/( |\t)/,'').downcase || ""
      @category
    end

    def short_time_range(opts={})
      return "" if all_day
      # TODO remove this, and set this in an appropriate global location
      Time.zone = 'Pacific Time (US & Canada)'
      start_time = (self.start.in_time_zone.strftime("%M")=='00') ?
        self.start.in_time_zone.strftime('%l') : self.start.in_time_zone.strftime('%l:%M')
      start_time += "p" if self.start.in_time_zone.strftime('%H').to_i > 12
      end_time = self.end.strftime("%H:%M")
      return "#{start_time} #{end_time}" if opts[:debug]
      "#{start_time}"
    end
    def day_span
      # figure out if we need to display for more than one day. minimum is 1 day
    end

    def original_event_id
      Nokogiri::XML(original_event).root['id']
    end
    def original_event_obj
      if original_event
        return calendar.events.find_by_uid original_event_id
      end
    end
    # This is different from _updated_at_, the magic AR column which is the last
    # time the AR object was written to.
    # updated is the last updated time as determined by the xml data (ie google).
    # We use this to determine if the AR object is stale.
    def updated
      time = xml.xpath('//updated').text
      Time.zone.parse(time)
    end
    def xml
      Nokogiri::XML(body)
    end
    #    def title=(v)
    #      #TODO all locally cached attributes need to update the xml body for when
    #      # sync needs to update the server
    #    end

    # returns true or false based on if this event is a single event or a recurring event
    def single_event?
      return true if recurring.blank? and original_event.nil?
      false
    end

    def rical
      return nil if recurring.blank?
      RiCal::parse_string("BEGIN:VEVENT\n"+recurring+"END:VEVENT").first
    end

    # returns nil if this is a single occurrence event
    # recurrences can be specified in two ways by the gapi.
    # 1. empty start/end times and no recurring tag
    # 2. start/end time set and a link to originalEvent
    def occurrences(range)
      return nil if single_event?

      # if original_event then get the id and search for it and use its recurrence data
      if original_event
        #recurr_obj = original_event_obj.try :rical
        recurr_obj = rical
      else
        recurr_obj = rical
      end

      rv = []
      recurr_obj.occurrences(:overlapping=>[range.first, range.last]).each { |rical_event|
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
    private
    
    def update_from(other)
      ["etag", "created_at", "title", "body", "author",
        "updated_at", "synced_at",
        "gcal_cal_id", "uid",
        "end", "start", "desc", "where", "recurring", "all_day"].each do |attr|
        write_attribute(attr, other.read_attribute(attr) )
      end
    end


  end

end

