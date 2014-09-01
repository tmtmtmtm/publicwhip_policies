# encoding: utf-8

require 'cgi'
require 'uri'

class PWScraper

  require 'json'
  require 'nokogiri'
  require 'open-uri'
  # require 'open-uri/cached'
  # OpenURI::Cache.cache_path = '/tmp/cache'

  @@PW_URL = 'http://www.publicwhip.org.uk/'

  def initialize(page)
    page = @@PW_URL + page unless page.start_with? 'http'
    @page = page
    @doc = Nokogiri::HTML(open(page))
  end

  def as_hash
    return structure
  end

end

class DivisionScraper < PWScraper

  def structure 
    return { 
      id: "pw-#{motion_date}-#{motion_id}",
      text: bill,
      date: motion_date,
      hansard: hansard,
      result: result,
      date: motion_date,
      datetime: datetime,
      votes: votes,
    }
  end

  def bill
    h1_parts.first
  end

  def datetime
    # "19 Nov 2003 at 16:45",
    (date_s, time_s) = h1_parts.last.split(/ at /)
    return if time_s.nil?
    (hh, mm) = time_s.split(/:/).map(&:to_i)
    date = Date.strptime(date_s, '%d %b %Y')
    if hh > 24
      hh -= 24
      date += 1
    end
    return DateTime.new(date.year, date.mon, date.mday, hh, mm, 0) 
  end

  def h1_parts
    @doc.at_css('#main h1').text.strip.reverse.split('—', 2).reverse.map(&:strip).map(&:reverse)
  end

  def id
    "pw-#{motion_date}-#{motion_id}"
  end

  def motion_date
    CGI.parse(pw_link.query)['date'].first
  end

  def motion_id
    CGI.parse(pw_link.query)['number'].first
  end

  def constituency_link 
    @doc.xpath("//a[text()='Constituency']/@href").text
  end

  def pw_link
    URI.parse(@@PW_URL + constituency_link.gsub('&sort=constituency',''))
  end

  def votes
    @votes ||= @doc.css('#votetable tr').drop(1).map { |voterow| 
      row = voterow.css('td')
      (who, where, party, vote) = row.map(&:text).map(&:strip)
      mpurl = row[0].xpath('./a/@href').first
      vote = {
        name: who,
        url: @@PW_URL + mpurl,
        constituency: where,
        party: party,
        option: vote,
      }
      if (vote[:option].start_with? 'tell')
        vote[:role] = 'teller'
        vote[:option].gsub!(/^tell/,'')
      end
      vote[:option] = 'yes' if vote[:option] == 'aye'
      vote
    }
  end

  def counts
    votes.group_by { |v| v[:option] }.map { |k,v| { option: k, value: v.count } }
  end

  def result
    (ys, ns) = %w(yes no).map { |want|
      counts.find { |c| c[:option] == want }[:value]
    }
    result = ys > ns ? "passed" : "failed"
  end

  def hansard
    hansard = @doc.xpath("//a[text()='Online Hansard']/@href").text
    hansard = @doc.xpath("//a[text()='Source']/@href").text if hansard.empty?
    raise "No hansard record in #{@page}" if hansard.empty?
    return hansard
  end
end

class PolicyScraper < PWScraper

  def structure 
    return { 
      text: policy_text,
      motions: motions.reject { |a| a.nil? }
    }
  end

  def policy_text
    policy = @doc.at_css('#main h1').text.strip
    policy_text = policy[/Policy #(\d+): "([^:]+)"/, 2]
    abort "No policy_text in #{policy}" if policy_text.empty?
    policy_text
  end

  def motions
    @doc.css('table.votes tr').drop(1).map { |prow|
      row = prow.css('td')
      (house, date, subject, direction) = row.map(&:text).map(&:strip)
      next unless house == 'Commons'
      votepage = row[2].xpath('./a/@href').first.text + '&display=allpossible'
      motion = DivisionScraper.new(votepage).as_hash
      motion[:direction] = direction
      motion
    }
  end
end



require 'scraperwiki'
require 'json'

@POLICIES = 'https://api.morph.io/tmtmtmtm/theyworkforyou_policies/data.json?query=select%20id%20from%20data&key='
url = @POLICIES + ENV['MORPH_KEY']
policy_ids = JSON.parse(open(url, {ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE}).read ).map { |e| e['id'].to_i }

def store_policy(pid)
  policy = PolicyScraper.new("policy.php?id=#{pid}").as_hash
  motions = policy.delete(:motions)
  motions.each do |m|
    m[:policy] = pid
    votes = m.delete(:votes)
    votes.each { |v| v[:motion] = m[:id] }
    puts "  #{m[:id]} #{m[:text]}"
    ScraperWiki.save_sqlite([:id, :policy], m)
    # Need to include :option to cope with "boths"
    ScraperWiki.save_sqlite([:motion, :constituency, :option], votes, 'votes')
  end
end

policy_ids.each do |pid|
  unless (ScraperWiki.select('* FROM data WHERE policy=?', pid).empty? rescue true) 
    puts "Skipping Policy #{pid}"
    next
  end
  puts "Fetching Policy #{pid}"
  store_policy(pid)
end

# Division pages don't include the unique voter id, only a link to a
# page that includes it!
ScraperWiki.sqliteexecute('DROP TABLE voters')
data = { url: 'http://www.publicwhip.org.uk/mp.php?mpn=Graham_Brady&mpc=Altrincham_and_Sale_West&house=commons', id: 10062 }
ScraperWiki.save_sqlite([:url, :id], data, 'voters')

voter_urls = ScraperWiki.select('DISTINCT v.url FROM votes v LEFT JOIN voters mp ON v.url = mp.url WHERE mp.id IS NULL') rescue false
voter_urls.map { |h| h['url'] }.each do |url|
  page = open(url).read
  if id = page[/<title>Voting Record \&.*?\((\d+)\) \&/,1]
    data = { url: url, id: id.to_i }
    ScraperWiki.save_sqlite([:url, :id], data, 'voters')
    puts "MP #{url} = #{id}"
  else
    puts "No id for #{url}"
  end
end

ScraperWiki.sqliteexecute('CREATE INDEX IF NOT EXISTS voterididx ON voters (id)')
ScraperWiki.sqliteexecute('CREATE INDEX IF NOT EXISTS voteurlidx ON votes (url)')

