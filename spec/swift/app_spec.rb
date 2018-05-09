require_relative "../spec_helper"

describe "Swift provider" do
  def container_url_for(user)
    "#{app.settings.swift["host"]}/rs:documents:test/#{user}"
  end

  def storage_class
    RemoteStorage::Swift
  end

  before do
    stub_request(:put, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { etag: "0815etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    # Write new content with an If-Match header (a new Etag is returned)
    stub_request(:put, "#{container_url_for("phil")}/food/aguacate").
      with(body: "aye").
      to_return(status: 200, headers: { etag: "0915etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:head, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:get, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, body: "rootbody", headers: { etag: "0817etag", content_type: "text/plain; charset=utf-8" })
    stub_request(:delete, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { etag: "0815etag" })

    # Write new content to check the metadata in Redis
    stub_request(:put, "#{container_url_for("phil")}/food/banano").
      with(body: "si").
      to_return(status: 200, headers: { etag: "0815etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:put, "#{container_url_for("phil")}/food/banano").
      with(body: "oh, no").
      to_return(status: 200, headers: { etag: "0817etag", last_modified: "Fri, 04 Mar 2016 12:20:20 GMT" })

    stub_request(:put, "#{container_url_for("phil")}/food/camaron").
      to_return(status: 200, headers: { etag: "0816etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:delete, "#{container_url_for("phil")}/food/camaron").
      to_return(status: 200, headers: { etag: "0816etag" })

    stub_request(:put, "#{container_url_for("phil")}/food/desayunos/bolon").
      to_return(status: 200, headers: { etag: "0817etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:delete, "#{container_url_for("phil")}/food/desayunos/bolon").
      to_return(status: 200, headers: { etag: "0817etag" })

    # objects in root dir
    stub_request(:put, "#{container_url_for("phil")}/bamboo.txt").
      to_return(status: 200, headers: { etag: "0818etag", last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })

    # 404
    stub_request(:head, "#{container_url_for("phil")}/food/steak").
      to_return(status: 404)
    stub_request(:get, "#{container_url_for("phil")}/food/steak").
      to_return(status: 404)
    stub_request(:delete, "#{container_url_for("phil")}/food/steak").
      to_return(status: 404)
  end

  it_behaves_like 'a REST adapter'
end
