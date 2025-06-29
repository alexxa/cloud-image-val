import pytest
import os  # noqa: F401

from main.cloud_image_validator import CloudImageValidator
from cloud.opentofu.opentofu_configurator import OpenTofuConfigurator
from cloud.opentofu.opentofu_controller import OpenTofuController
from test_suite.suite_runner import SuiteRunner


class TestCloudImageValidator:
    test_config = {'resources_file': '/fake/test/resources_file.json',
                   'output_file': '/fake/test/output_file.xml',
                   'test_filter': 'test_test_name',
                   'include_markers': 'pub',
                   'parallel': True,
                   'debug': True,
                   'stop_cleanup': False,
                   'config_file': '/tmp/test_config_file.yml',
                   'test_suites': ['test_path_1', 'test_path_2'],
                   'instances_json': '/tmp/instances.json',
                   'ssh_identity_file': '/tmp/ssh_key',
                   'ssh_pub_key_file': '/tmp/ssh_key.pub',
                   'ssh_config_file': '/tmp/ssh_key.pub'
                   }
    test_instances = {
        'instance-1': {'public_dns': 'value_1', 'username': 'value_2'},
        'instance-2': {'public_dns': 'value_1', 'username': 'value_2'}
    }

    @pytest.fixture
    def validator(self):
        return CloudImageValidator(config=self.test_config)

    def test_main(self, mocker, validator):
        # Arrange
        test_controller = 'test controller'
        wait_status_test = 32512
        exit_code_test = 127

        mock_initialize_infrastructure = mocker.MagicMock(return_value=test_controller)
        validator.initialize_infrastructure = mock_initialize_infrastructure

        mock_print_divider = mocker.patch('lib.console_lib.print_divider')

        mock_deploy_infrastructure = mocker.MagicMock(return_value=self.test_instances)
        validator.deploy_infrastructure = mock_deploy_infrastructure

        mock_prepare_environment = mocker.MagicMock()
        validator.prepare_environment = mock_prepare_environment

        mock_run_tests_in_all_instances = mocker.MagicMock(return_value=wait_status_test)
        validator.run_tests_in_all_instances = mock_run_tests_in_all_instances

        mock_cleanup = mocker.MagicMock()
        validator.cleanup = mock_cleanup

        # Act
        result = validator.main()

        # Assert
        assert result == exit_code_test

        assert mock_print_divider.call_args_list == [
            mocker.call('Initializing infrastructure'),
            mocker.call('Deploying infrastructure'),
            mocker.call('Preparing environment'),
            mocker.call('Running tests'),
            mocker.call('Cleanup')
        ]

        mock_initialize_infrastructure.assert_called_once()
        mock_deploy_infrastructure.assert_called_once()
        mock_run_tests_in_all_instances.assert_called_once_with(self.test_instances)
        mock_prepare_environment.assert_called_once_with(self.test_instances)
        mock_cleanup.assert_called_once()

    def test_initialize_infrastructure(self, mocker, validator):
        # Arrange
        mocker.patch('lib.ssh_lib.generate_ssh_key_pair')
        mock_get_cloud_provider_from_resources = mocker.patch.object(OpenTofuConfigurator,
                                                                     'get_cloud_provider_from_resources')
        mock_configure_from_resources_json = mocker.patch.object(OpenTofuConfigurator,
                                                                 'configure_from_resources_json')
        mock_print_configuration = mocker.patch.object(OpenTofuConfigurator,
                                                       'print_configuration')
        mock_initialize_resources_dict = mocker.patch.object(OpenTofuConfigurator,
                                                             '_initialize_resources_dict')

        # Act
        validator.initialize_infrastructure()

        # Assert
        mock_get_cloud_provider_from_resources.assert_called_once()
        mock_configure_from_resources_json.assert_called_once()
        mock_print_configuration.assert_called_once()
        mock_initialize_resources_dict.assert_called_once()

    def test_deploy_infrastructure(self, mocker, validator):
        # Arrange
        mocker.patch.object(OpenTofuConfigurator, 'cloud_name', create=True)

        mock_create_infra = mocker.patch.object(OpenTofuController,
                                                'create_infra')
        mock_get_instances = mocker.patch.object(OpenTofuController,
                                                 'get_instances',
                                                 return_value=self.test_instances)
        mock_generate_instances_ssh_config = mocker.patch('lib.ssh_lib.generate_instances_ssh_config')

        mock_write_instances_to_json = mocker.MagicMock()
        validator._write_instances_to_json = mock_write_instances_to_json

        validator.infra_controller = OpenTofuController(OpenTofuConfigurator)

        # Act
        result = validator.deploy_infrastructure()

        # Assert
        assert result == self.test_instances

        mock_create_infra.assert_called_once()
        mock_get_instances.assert_called_once()
        mock_write_instances_to_json.assert_called_once_with(
            self.test_instances)
        mock_generate_instances_ssh_config.assert_called_once_with(instances=self.test_instances,
                                                                   ssh_config_file=validator.config['ssh_config_file'],
                                                                   ssh_key_path=validator.config['ssh_identity_file'])

    def test_prepare_environment(self, mocker, validator):
        mock_add_ssh_keys_to_instances = mocker.patch('lib.ssh_lib.add_ssh_keys_to_instances')

        validator.prepare_environment(self.test_instances)

        mock_add_ssh_keys_to_instances.assert_called_once_with(self.test_instances,
                                                               validator.config['ssh_config_file'])

    def test_run_tests_in_all_instances(self, mocker, validator):
        mocker.patch.object(OpenTofuConfigurator, 'cloud_name', create=True)
        validator.infra_configurator = OpenTofuConfigurator

        mock_run_tests = mocker.patch.object(SuiteRunner, 'run_tests')

        validator.run_tests_in_all_instances(self.test_instances)

        mock_run_tests.assert_called_once_with(self.test_config["test_suites"],
                                               validator.config["output_file"],
                                               self.test_config["test_filter"],
                                               self.test_config["include_markers"])

    def test_destroy_infrastructure(self, mocker, validator):
        mock_destroy_infra = mocker.patch.object(OpenTofuController, 'destroy_infra')
        validator.infra_controller = OpenTofuController
        validator.config["debug"] = False

        mock_os_remove = mocker.patch('os.remove')

        validator.cleanup()

        mock_destroy_infra.assert_called_once()

        assert mock_os_remove.call_args_list == [
            mocker.call(validator.config['ssh_identity_file']),
            mocker.call(validator.config['ssh_pub_key_file']),
            mocker.call(validator.config['ssh_config_file']),
            mocker.call(validator.config['instances_json'])
        ]

    def test_attach_infrastructure(self, mocker, validator):
        # Arrange
        mock_opentofu_configurator = mocker.patch('main.cloud_image_validator.OpenTofuConfigurator')
        mock_opentofu_controller = mocker.patch('main.cloud_image_validator.OpenTofuController')

        # Act
        result = validator.attach_infrastructure()

        # Assert
        mock_opentofu_configurator.assert_called_once_with(
            ssh_key_path=validator.config['ssh_pub_key_file'],
            resources_path=validator.config['resources_file'],
            config=validator.config
        )
        mock_opentofu_controller.assert_called_once_with(
            mock_opentofu_configurator.return_value,
            validator.config['debug']
        )
        assert result == mock_opentofu_controller.return_value

    def test_attach_instances(self, mocker, validator):
        # Arrange
        mock_infra_controller = mocker.patch.object(validator, 'infra_controller')
        mock_get_instances = mocker.patch.object(mock_infra_controller, 'get_instances')

        # Act
        result = validator.attach_instances()

        # Assert
        mock_get_instances.assert_called_once()
        assert result == mock_get_instances.return_value

    def test_print_ssh_commands_for_instances(self, validator):
        # Arrange
        instances = {
            'instance-1': {'name': 'instance-1', 'username': 'user1', 'address': 'address1'},
            'instance-2': {'name': 'instance-2', 'username': 'user2', 'address': 'address2'}
        }
        expected_output = """instance-1:
\tssh -i /tmp/ssh_key user1@address1
instance-2:
\tssh -i /tmp/ssh_key user2@address2
"""

        # Act
        import io
        from contextlib import redirect_stdout

        f = io.StringIO()
        with redirect_stdout(f):
            validator.print_ssh_commands_for_instances(instances)
        result = f.getvalue()

        # Assert
        assert result == expected_output
