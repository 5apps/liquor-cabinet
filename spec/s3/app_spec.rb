require_relative "../spec_helper"

describe "S3 provider" do
  def container_url_for(user)
    "#{app.settings.s3["endpoint"]}#{app.settings.s3["bucket"]}/#{user}"
  end

  def storage_class
    RemoteStorage::S3
  end

  before do
    stub_request(:put, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { etag: '"0815etag"',  date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    # Write new content with an If-Match header (a new Etag is returned)
    stub_request(:put, "#{container_url_for("phil")}/food/aguacate").
      with(body: "aye").
      to_return(status: 200, headers: { etag: '"0915etag"', date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:put, "#{container_url_for("phil")}/public/shares/example.jpg").
      to_return(status: 200, headers: { etag: '"0817etag"', content_type: "image/jpeg", date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:put, "#{container_url_for("phil")}/public/shares/example_partial.jpg").
      to_return(status: 200, headers: { etag: '"0817etag"', content_type: "image/jpeg", date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:head, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:get, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, body: "rootbody", headers: { etag: '"0817etag"', content_type: "text/plain; charset=utf-8" })
    stub_request(:delete, "#{container_url_for("phil")}/food/aguacate").
      to_return(status: 200, headers: { etag: '"0815etag"' })
    stub_request(:get, "#{container_url_for("phil")}/public/shares/example.jpg").
      to_return(status: 200, body: "", headers: { etag: '"0817etag"', content_type: "image/jpeg" })
    stub_request(:get, "#{container_url_for("phil")}/public/shares/example_partial.jpg").
      to_return(status: 206, body: "", headers: { etag: '"0817etag"', content_type: "image/jpeg", content_range: "bytes 0-16/128" })

    # Write new content to check the metadata in Redis
    stub_request(:put, "#{container_url_for("phil")}/food/banano").
      with(body: "si").
      to_return(status: 200, headers: { etag: '"0815etag"', date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:put, "#{container_url_for("phil")}/food/banano").
      with(body: "oh, no").
      to_return(status: 200, headers: { etag: '"0817etag"', date: "Fri, 04 Mar 2016 12:20:20 GMT" })

    stub_request(:put, "#{container_url_for("phil")}/food/camaron").
      to_return(status: 200, headers: { etag: '"0816etag"', date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:head, "#{container_url_for("phil")}/food/camaron").
      to_return(status: 200, headers: { last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:delete, "#{container_url_for("phil")}/food/camaron").
      to_return(status: 200, headers: { etag: '"0816etag"' })

    stub_request(:put, "#{container_url_for("phil")}/food/desayunos/bolon").
      to_return(status: 200, headers: { etag: '"0817etag"', date: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:head, "#{container_url_for("phil")}/food/desayunos/bolon").
      to_return(status: 200, headers: { last_modified: "Fri, 04 Mar 2016 12:20:18 GMT" })
    stub_request(:delete, "#{container_url_for("phil")}/food/desayunos/bolon").
      to_return(status: 200, headers: { etag: '"0817etag"' })

    # objects in root dir
    stub_request(:put, "#{container_url_for("phil")}/bamboo.txt").
      to_return(status: 200, headers: { etag: '"0818etag"', date: "Fri, 04 Mar 2016 12:20:18 GMT" })

    # 404
    stub_request(:head, "#{container_url_for("phil")}/food/steak").
      to_return(status: 404)
    stub_request(:get, "#{container_url_for("phil")}/food/steak").
      to_return(status: 404)
  end

  it_behaves_like 'a REST adapter'
end
