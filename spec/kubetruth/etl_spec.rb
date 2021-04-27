require 'rspec'
require 'kubetruth/etl'

module Kubetruth
  describe ETL do

    let(:init_args) {{
      config_file: "kubetruth.yaml", ct_context: {}, kube_context: {}
    }}

    def kubeapi(ns)
      kapi = double(Kubetruth::KubeApi)
      allow(Kubetruth::KubeApi).to receive(:new).with(hash_including(namespace: ns)).and_return(kapi)
      allow(kapi).to receive(:get_config_map_names).and_return([])
      allow(kapi).to receive(:get_secret_names).and_return([])
      allow(kapi).to receive(:ensure_namespace) unless ns.nil?
      allow(kapi).to receive(:namespace).and_return(ns.nil? ? "default_ns" : ns)
      kapi
    end

    around(:each) do |ex|
      within_construct do |c|
        c.file('kubetruth.yaml', "")
        ex.run
      end
    end

    before(:each) do
      @ctapi_class = Class.new
      @ctapi = double()
      allow(Kubetruth).to receive(:CtApi).and_return(@ctapi_class)
      allow(@ctapi_class).to receive(:new).and_return(@ctapi)

      @kubeapi = kubeapi("")
    end

    describe "#ctapi" do

      it "is memoized" do
        etl = described_class.new(init_args)
        expect(etl.ctapi).to equal(etl.ctapi)
      end

    end

    describe "#kubeapi" do

      it "passes namespace to ctor" do
        etl = described_class.new(init_args)
        expect(Kubetruth::KubeApi).to receive(:new).with(hash_including(namespace: "foo"))
        etl.kubeapi("foo")
      end

      it "overrides namespace from kube context in ctor" do
        etl = described_class.new(init_args.merge({kube_context: {namespace: "bar"}}))
        expect(Kubetruth::KubeApi).to receive(:new).with(hash_including(namespace: "foo"))
        etl.kubeapi("foo")
      end

      it "is memoized" do
        etl = described_class.new(init_args)
        expect(etl.kubeapi("")).to equal(etl.kubeapi(""))
      end

      it "same behavior with nil or blank namespace" do
        etl = described_class.new(init_args)
        expect(etl.kubeapi("")).to equal(etl.kubeapi(nil))
      end

    end

    describe "#dns_friendly" do

      it "cleans up name" do
        etl = described_class.new(init_args)
        expect(etl.dns_friendly("foo_bar")).to eq("foo-bar")
      end

      it "simplifies successive non-chars" do
        etl = described_class.new(init_args)
        expect(etl.dns_friendly("foo_&!bar")).to eq("foo-bar")
      end

      it "strips leading/trailing non-chars" do
        etl = described_class.new(init_args)
        expect(etl.dns_friendly("_foo!bar_")).to eq("foo-bar")
      end

    end

    describe "#load_config" do

      it "loads config" do
        etl = described_class.new(init_args)
        config = etl.load_config
        expect(config).to be_an_instance_of(Kubetruth::Config)
        expect(etl.load_config).to equal(config)
        sleep(0.2) # fails on GithubActions without this
        File.write(init_args[:config_file], "---")
        expect(etl.load_config).to_not equal(config)
      end

    end

    describe "#get_params" do

      let(:etl) { described_class.new(init_args) }
      let(:project) { "foo" }
      let(:project_spec) { etl.load_config.spec_for_project(project) }

      it "handles empty" do
        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([])
        params = etl.get_params(project, project_spec)
        expect(params).to eq([])
      end

      it "only selects for matching key_filter" do
        project_spec.key_filter = "svc"
        expect(@ctapi).to receive(:parameters).with(searchTerm: "svc", project: "foo").and_return([])
        params = etl.get_params(project, project_spec)
      end

      it "only selects for matching selector" do
        project_spec.key_selector = /foo$/
        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([
          Parameter.new(key: "svc.param1", value: "value1", secret: false),
          Parameter.new(key: "svc.param2.foo", value: "value2", secret: false),
        ])
        params = etl.get_params(project, project_spec)
        expect(params.size).to eq(1)
        expect(params.collect(&:original_key)).to eq(["svc.param2.foo"])
      end

      it "applies templates to matches" do
        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([
            Parameter.new(key: "foo.key1", value: "value1", secret: false),
            Parameter.new(key: "bar.key2", value: "value2", secret: false)
        ])
        project_spec.key_selector = /^(?<prefix>.*)\.(?<key>.*)$/
        project_spec.key_template = "%{key}_%{prefix}_%{project}"
        params = etl.get_params(project, project_spec, template_matches: {project: "myproj"})
        expect(params.size).to eq(2)
        expect(params).to eq([
          Parameter.new(original_key: "foo.key1", key: "key1_foo_myproj", value: "value1", secret: false),
          Parameter.new(original_key: "bar.key2", key: "key2_bar_myproj", value: "value2", secret: false)
        ])
      end

      it "sets key in template if not in selector" do
        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([
          Parameter.new(key: "key1", value: "value1", secret: false),
        ])
        project_spec.key_selector = //
        project_spec.key_template = "my_%{key}"
        params = etl.get_params(project, project_spec)
        expect(params).to eq([
                               Parameter.new(original_key: "key1", key: "my_key1", value: "value1", secret: false),
                             ])
      end

      it "has a number of template options" do
        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([
          Parameter.new(key: "svc.name1.key1", value: "value1", secret: false),
        ])
        project_spec.key_selector = /^(?<prefix>[^\.]+)\.(?<name>[^\.]+)\.(?<key>.*)/
        project_spec.key_template = "start.%{key}.%{name}.%{prefix}.middle.%{key_upcase}.%{name_upcase}.%{prefix_upcase}.end"
        params = etl.get_params(project, project_spec)
        expect(params).to eq([
                               Parameter.new(original_key: "svc.name1.key1", key: "start.key1.name1.svc.middle.KEY1.NAME1.SVC.end", value: "value1", secret: false)
                             ])
      end

      it "doesn't expose secret in debug log" do
        Logging.setup_logging(level: :debug, color: false)

        expect(@ctapi).to receive(:parameters).with(searchTerm: "", project: "foo").and_return([
                                                              Parameter.new(key: "param1", value: "value1", secret: false),
                                                              Parameter.new(key: "param2", value: "sekret", secret: true),
                                                              Parameter.new(key: "param3", value: "alsosekret", secret: true),
                                                              Parameter.new(key: "param4", value: "value4", secret: false),
                                                          ])
        params = etl.get_params(project, project_spec)
        expect(Logging.contents).to include("param2")
        expect(Logging.contents).to include("param3")
        expect(Logging.contents).to include("<masked>")
        expect(Logging.contents).to_not include("sekret")
      end

    end

    describe "#apply_config_map" do

      let(:etl) { described_class.new(init_args) }

      it "calls kube to create new config map" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: false)
        ]
        expect(@kubeapi).to receive(:get_config_map).with("group1").and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(@kubeapi).to_not receive(:update_config_map)
        expect(@kubeapi).to receive(:create_config_map).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_config_map(namespace: '', name: "group1", params: params)
      end

      it "calls kube to update config map" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: false)
        ]
        resource = Kubeclient::Resource.new
        resource.data = {oldparam: "oldvalue"}
        expect(@kubeapi).to receive(:get_config_map).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(true)
        expect(@kubeapi).to_not receive(:create_config_map)
        expect(@kubeapi).to receive(:update_config_map).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_config_map(namespace: '', name: "group1", params: params)
      end

      it "doesn't update config map if data same" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: false)
        ]
        resource = Kubeclient::Resource.new
        resource.data = {param1: "value1", param2: "value2"}
        expect(@kubeapi).to receive(:get_config_map).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(true)
        expect(@kubeapi).to_not receive(:create_config_map)
        expect(@kubeapi).to_not receive(:update_config_map)
        etl.apply_config_map(namespace: '', name: "group1", params: params)
      end

      it "doesn't update config map if not under management" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: false)
        ]
        resource = Kubeclient::Resource.new
        resource.data = {oldparam: "oldvalue"}
        expect(@kubeapi).to receive(:get_config_map).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(false)
        expect(@kubeapi).to_not receive(:create_config_map)
        expect(@kubeapi).to_not receive(:update_config_map)
        etl.apply_config_map(namespace: '', name: "group1", params: params)
        expect(Logging.contents).to match(/Skipping config map 'group1'/)
      end

      it "uses namespace for kube when supplied" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: false)
        ]
        foo_kapi = kubeapi("foo")
        expect(etl).to receive(:kubeapi).with("foo").at_least(:once).and_return(foo_kapi)
        expect(foo_kapi).to receive(:get_config_map).with("group1").and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(foo_kapi).to_not receive(:update_config_map)
        expect(foo_kapi).to receive(:create_config_map).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_config_map(namespace: 'foo', name: "group1", params: params)
      end

    end

    describe "#apply_secret" do

      let(:etl) { described_class.new(init_args) }

      it "calls kube to create new secret" do
        params = [
            Parameter.new(key: "param1", value: "value1", secret: true),
            Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        expect(@kubeapi).to receive(:get_secret).with("group1").and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(@kubeapi).to_not receive(:update_secret)
        expect(@kubeapi).to receive(:create_secret).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_secret(namespace: '', name: "group1", params: params)
      end

      it "calls kube to update secret" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: true),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        resource = Kubeclient::Resource.new
        resource.stringData = {oldparam: "oldvalue"}
        expect(@kubeapi).to receive(:get_secret).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(true)
        expect(@kubeapi).to receive(:secret_hash).with(resource).and_return({oldparam: "oldvalue"})
        expect(@kubeapi).to_not receive(:create_secret)
        expect(@kubeapi).to receive(:update_secret).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_secret(namespace: '', name: "group1", params: params)
      end

      it "doesn't update secret if data same" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: true),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        resource = Kubeclient::Resource.new
        resource.stringData = {param1: "value1", param2: "value2"}
        expect(@kubeapi).to receive(:get_secret).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(true)
        expect(@kubeapi).to receive(:secret_hash).with(resource).and_return({param1: "value1", param2: "value2"})
        expect(@kubeapi).to_not receive(:create_secret)
        expect(@kubeapi).to_not receive(:update_secret)
        etl.apply_secret(namespace: '', name: "group1", params: params)
      end

      it "doesn't update secret if not under management=" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: true),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        resource = Kubeclient::Resource.new
        resource.stringData = {oldparam: "oldvalue"}
        expect(@kubeapi).to receive(:get_secret).with("group1").and_return(resource)
        expect(@kubeapi).to receive(:under_management?).with(resource).and_return(false)
        expect(@kubeapi).to receive(:secret_hash).with(resource).and_return({oldparam: "oldvalue"})
        expect(@kubeapi).to_not receive(:create_secret)
        expect(@kubeapi).to_not receive(:update_secret)
        etl.apply_secret(namespace: '', name: "group1", params: params)
        expect(Logging.contents).to match(/Skipping secret 'group1'/)
      end

      it "uses namespace for kube when supplied" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: true),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        foo_kapi = kubeapi("foo")
        expect(foo_kapi).to receive(:get_secret).with("group1").and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(foo_kapi).to_not receive(:update_secret)
        expect(foo_kapi).to receive(:create_secret).with("group1", {"param1" => "value1", "param2" => "value2"})
        etl.apply_secret(namespace: 'foo', name: "group1", params: params)
      end

    end

    describe "#apply" do

      let(:etl) { described_class.new(init_args) }

      it "sets config and secrets" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        expect(etl.ctapi).to receive(:project_names).and_return(["default"])
        expect(etl).to receive(:get_params).and_return(params)
        expect(etl).to receive(:apply_config_map).with(namespace: '', name: "default", params: [params[0]])
        expect(etl).to receive(:apply_secret).with(namespace: '', name: "default", params: [params[1]])
        etl.apply()
      end

      it "skips secrets" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        etl.load_config.root_spec.skip_secrets = true
        expect(etl.ctapi).to receive(:project_names).and_return(["default"])
        expect(etl).to receive(:get_params).and_return(params)
        expect(etl).to receive(:apply_config_map).with(namespace: '', name: "default", params: [params[0]])
        expect(etl).to_not receive(:apply_secret)
        etl.apply()
      end

      it "allows dryrun" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        etl.load_config.root_spec.skip_secrets = true
        expect(etl.ctapi).to receive(:project_names).and_return(["default"])
        expect(etl).to receive(:get_params).and_return(params)
        expect(etl).to_not receive(:apply_config_map)
        expect(etl).to_not receive(:apply_secret)
        etl.apply(dry_run: true)
        expect(Logging.contents).to match("Performing dry-run")
      end

      it "makes name and namespace dns safe" do
        params = [
          Parameter.new(key: "param1", value: "value1", secret: false),
          Parameter.new(key: "param2", value: "value2", secret: true)
        ]
        etl.load_config.root_spec.namespace_template = "ns_%{project}"
        etl.load_config.root_spec.configmap_name_template = "cm_%{project}"
        etl.load_config.root_spec.secret_name_template = "s_%{project}"
        expect(etl.ctapi).to receive(:project_names).and_return(["default"])
        expect(etl).to receive(:get_params).and_return(params)
        expect(etl).to receive(:apply_config_map).with(namespace: 'ns-default', name: "cm-default", params: [params[0]])
        expect(etl).to receive(:apply_secret).with(namespace: 'ns-default', name: "s-default", params: [params[1]])
        etl.apply()
      end

      it "skips projects when selector fails" do
        etl.load_config.root_spec.project_selector = /oo/
        expect(etl.ctapi).to receive(:project_names).and_return(["default", "foo", "bar"])
        expect(etl).to_not receive(:get_params).with("default", any_args)
        expect(etl).to receive(:get_params).with("foo", any_args).and_return([])
        expect(etl).to_not receive(:get_params).with("bar", any_args)
        expect(etl).to receive(:apply_config_map)
        expect(etl).to receive(:apply_secret)
        etl.apply()
      end

      it "skips projects if flag is set" do
        within_construct do |c|
          c.file('kubetruth.yaml', YAML.dump(
            project_overrides: [
              {project_selector: "foo", skip: true}
            ]
          ))

          expect(etl.ctapi).to receive(:project_names).and_return(["default", "foo", "bar"])
          expect(etl).to receive(:get_params).with("default", any_args).and_return([])
          expect(etl).to_not receive(:get_params).with("foo", any_args)
          expect(etl).to receive(:get_params).with("bar", any_args).and_return([])
          allow(etl).to receive(:apply_config_map)
          allow(etl).to receive(:apply_secret)
          etl.apply()
        end
      end

      it "gets captures for template from both levels of project selectors" do
        within_construct do |c|
          c.file('kubetruth.yaml', YAML.dump(
            project_selector: "^(?<root_match>[^.]+)",
            namespace_template: "%{child_match}-%{root_match}",
            key_template: "%{root_match}:%{child_match}:%{project}:%{key}",
            project_overrides: [
              {project_selector: "(?<child_match>[^.]+)$"}
            ]
          ))

          params = [
            Parameter.new(key: "param1", value: "value1", secret: false)
          ]
          expect(etl.ctapi).to receive(:project_names).and_return(["foo.bar"])
          expect(etl.ctapi).to receive(:parameters).and_return(params)
          expect(etl).to receive(:apply_config_map).
            with(namespace: 'bar-foo',
                 name: "foo.bar",
                 params: [Parameter.new(key: "foo:bar:foo.bar:param1", original_key: "param1", value: "value1", secret: false),])
          expect(etl).to receive(:apply_secret)
          etl.apply
        end
      end

    end

  end
end
