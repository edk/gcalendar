module GCalendar

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

