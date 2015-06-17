# Represents a single Problem. The problem may have been
# reported as various Errs, but the user has grouped the
# Errs together as belonging to the same problem.

class Problem
  include Mongoid::Document
  include Mongoid::Timestamps

  CACHED_NOTICE_ATTRIBUTES = {
    messages: :message,
    hosts: :host,
    user_agents: :user_agent_string
  }.freeze


  field :last_notice_at, :type => ActiveSupport::TimeWithZone, :default => Proc.new { Time.now }
  field :first_notice_at, :type => ActiveSupport::TimeWithZone, :default => Proc.new { Time.now }
  field :last_deploy_at, :type => Time
  field :resolved, :type => Boolean, :default => false
  field :resolved_at, :type => Time
  field :issue_link, :type => String
  field :issue_type, :type => String

  # Cached fields
  field :app_name, :type => String
  field :notices_count, :type => Integer, :default => 0
  field :message
  field :environment
  field :error_class
  field :where
  field :user_agents, :type => Hash, :default => {}
  field :messages,    :type => Hash, :default => {}
  field :hosts,       :type => Hash, :default => {}
  field :comments_count, :type => Integer, :default => 0

  index :app_id => 1
  index :app_name => 1
  index :message => 1
  index :last_notice_at => 1
  index :first_notice_at => 1
  index :last_deploy_at => 1
  index :resolved_at => 1
  index :notices_count => 1

  belongs_to :app
  has_many :errs, :inverse_of => :problem, :dependent => :destroy
  has_many :comments, :inverse_of => :err, :dependent => :destroy

  validates_presence_of :environment

  before_create :cache_app_attributes
  before_save :truncate_message

  scope :resolved, ->{ where(:resolved => true) }
  scope :unresolved, ->{ where(:resolved => false) }
  scope :ordered, ->{ order_by(:last_notice_at.desc) }
  scope :for_apps, lambda {|apps| where(:app_id.in => apps.all.map(&:id))}

  validates_presence_of :last_notice_at, :first_notice_at

  def self.all_else_unresolved(fetch_all)
    if fetch_all
      all
    else
      where(:resolved => false)
    end
  end

  def self.in_env(env)
    env.present? ? where(:environment => env) : scoped
  end

  def self.cache_notice(id, notice)
    # increment notice count
    message_digest = Digest::MD5.hexdigest(notice.message)
    host_digest = Digest::MD5.hexdigest(notice.host)
    user_agent_digest = Digest::MD5.hexdigest(notice.user_agent_string)

    Problem.where('_id' => id).find_one_and_update({
      '$set' => {
        'environment' => notice.environment_name,
        'error_class' => notice.error_class,
        'last_notice_at' => notice.created_at.utc,
        'message' => notice.message,
        'resolved' => false,
        'resolved_at' => nil,
        'where' => notice.where,
        "messages.#{message_digest}.value" => notice.message,
        "hosts.#{host_digest}.value" => notice.host,
        "user_agents.#{user_agent_digest}.value" => notice.user_agent_string,
      },
      '$inc' => {
        'notices_count' => 1,
        "messages.#{message_digest}.count" => 1,
        "hosts.#{host_digest}.count" => 1,
        "user_agents.#{user_agent_digest}.count" => 1,
      }
    }, return_document: :after)
  end

  def uncache_notice(notice)
    last_notice = notices.last

    atomically do |doc|
      doc.set(
        'environment' => last_notice.environment_name,
        'error_class' => last_notice.error_class,
        'last_notice_at' => last_notice.created_at,
        'message' => last_notice.message,
        'where' => last_notice.where,
        'notices_count' => notices_count.to_i > 1 ? notices_count - 1 : 0
      )

      CACHED_NOTICE_ATTRIBUTES.each do |k,v|
        digest = Digest::MD5.hexdigest(notice.send(v))
        field = "#{k}.#{digest}"

        if (doc[k].try(:[], digest).try(:[], :count)).to_i > 1
          doc.inc("#{field}.count" => -1)
        else
          doc.unset(field)
        end
      end
    end
  end

  def recache
    CACHED_NOTICE_ATTRIBUTES.each do |k,v|
      # clear all cached attributes
      send("#{k}=", {})

      # find only notices related to this problem
      Notice.collection.find.aggregate([
        { "$match" => { err_id: { "$in" => err_ids } } },
        { "$group" => { _id: "$#{v}", count: {"$sum" => 1} } }
      ]).each do |agg|
        next if agg[:_id] == nil

        send(k)[Digest::MD5.hexdigest(agg[:_id])] = {
          value: agg[:_id],
          count: agg[:count]
        }
      end
    end

    self.notices_count = Notice.where({ err_id: { "$in" => err_ids }}).count
    save
  end

  def url
    Rails.application.routes.url_helpers.app_problem_url(app, self,
      :host => Errbit::Config.host,
      :port => Errbit::Config.port
    )
  end

  def notices
    Notice.for_errs(errs).ordered
  end

  def resolve!
    self.update_attributes!(:resolved => true, :resolved_at => Time.now)
  end

  def unresolve!
    self.update_attributes!(:resolved => false, :resolved_at => nil)
  end

  def unresolved?
    !resolved?
  end


  def self.merge!(*problems)
    ProblemMerge.new(problems).merge
  end

  def merged?
    errs.length > 1
  end

  def unmerge!
    attrs = {:error_class => error_class, :environment => environment}
    problem_errs = errs.to_a

    # associate and return all the problems
    new_problems = [self]

    # create new problems for each err that needs one
    (problem_errs[1..-1] || []).each do |err|
      new_problems << app.problems.create(attrs)
      err.update_attribute(:problem, new_problems.last)
    end

    # recache each new problem
    new_problems.each(&:recache)

    new_problems
  end

  def self.ordered_by(sort, order)
    case sort
    when "app";            order_by(["app_name", order])
    when "message";        order_by(["message", order])
    when "last_notice_at"; order_by(["last_notice_at", order])
    when "last_deploy_at"; order_by(["last_deploy_at", order])
    when "count";          order_by(["notices_count", order])
    else raise("\"#{sort}\" is not a recognized sort")
    end
  end

  def self.in_date_range(date_range)
    where(:first_notice_at.lte => date_range.end).where("$or" => [{:resolved_at => nil}, {:resolved_at.gte => date_range.begin}])
  end

  def cache_app_attributes
    if app
      self.app_name = app.name
      self.last_deploy_at = app.last_deploy_at
    end
  end

  def truncate_message
    self.message = self.message[0, 1000] if self.message
  end

  def issue_type
    # Return issue_type if configured, but fall back to detecting app's issue tracker
    attributes['issue_type'] ||=
    (app.issue_tracker_configured? && app.issue_tracker.type_tracker) || nil
  end

  def self.search(value)
    any_of(
      {:error_class => /#{value}/i},
      {:where => /#{value}/i},
      {:message => /#{value}/i},
      {:app_name => /#{value}/i},
      {:environment => /#{value}/i}
    )
  end

  private

    def attribute_count_descrease(name, value)
      counter, index = send(name), attribute_index(value)
      if counter[index] && counter[index]['count'] > 1
        counter[index]['count'] -= 1
      else
        counter.delete(index)
      end
      counter
    end

    def attribute_index(value)
      Digest::MD5.hexdigest(value.to_s)
    end
end
