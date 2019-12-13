using AccountApi;
using AccountManager.Views.Dialogs;
using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Settings
{
    class WisaSettings :INotifyPropertyChanged
    {
        State.Wisa.WisaState state;

        public IAsyncCommand TestConnectionCommand { get; private set; }
        public IAsyncCommand AddRuleCommand { get; private set; }
        public IAsyncCommand<IRule> EditRuleCommand { get; set; }
        public ICommand DeleteRuleCommand { get; set; }

        public IAsyncCommand ReloadCommand { get; set; }
        public ICommand SelectSchoolsCommand { get; set; }

        public WisaSettings()
        {
            state = State.App.Instance.Wisa;
            this.TestConnectionCommand = new RelayAsyncCommand(TestConnection);
            this.AddRuleCommand = new RelayAsyncCommand(AddRule);
            this.EditRuleCommand = new RelayAsyncCommand<IRule>(EditRule);
            this.DeleteRuleCommand = new RelayCommand<IRule>(DeleteRule);
            this.ReloadCommand = new RelayAsyncCommand(ReloadSchools);
            this.SelectSchoolsCommand = new RelayCommand(SelectSchools);
        }

        private void SelectSchools()
        {
            state.Schools.SaveToJson();
        }

        private async Task ReloadSchools()
        {
            ShowReloadIndicator = true;
            state.Connect();
            await state.Schools.Load();
            ShowReloadIndicator = false;
        }

        private void DeleteRule(IRule parameter)
        {
            state.ImportRules.Remove(parameter);
        }

        private async Task EditRule(IRule parameter)
        {
            IRuleEditor editor = null;
            
            switch (parameter.Rule)
            {
                case Rule.WI_ReplaceInstitution: editor = new WI_ReplaceInstitute(parameter); break;
                case Rule.WI_DontImportClass: editor = new WI_DontImportClass(parameter); break;
                case Rule.WI_MarkAsVirtual: editor = new WI_MarkAsVirtual(parameter); break;
            }
            if (editor != null)
            {
                await DialogHost.Show(
                    editor,
                    "RootDialog"
                ).ConfigureAwait(false);
            }
        }

        private async Task AddRule()
        {
            var dialog = new ImportRuleSelectDialog(AccountApi.RuleType.WISA_Import);
            await DialogHost.Show(
                dialog,
                "RootDialog",
                (sender, eventArgs) =>
                {
                    var result = eventArgs.Parameter as string;
                    if (result == "true")
                    {
                        var rule = state.AddimportRule(dialog.SelectedRule);
                        eventArgs.Handled = true;
                    }
                }
            ).ConfigureAwait(false);
        }

        private async Task TestConnection()
        {
            ShowConnectIndicator = true;
            state.Connect();
            bool result = await AccountApi.Wisa.Connector.TestConnection();
            if (!result) ConnectIcon = PackIconKind.CloudOffOutline;
            else ConnectIcon = PackIconKind.CloudTick;
            ShowConnectIndicator = false;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        bool showConnectIndicator = false;
        public bool ShowConnectIndicator
        {
            get => showConnectIndicator;
            set
            {
                showConnectIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ShowConnectIndicator)));
            }
        }

        bool showReloadIndicator = false;
        public bool ShowReloadIndicator
        {
            get => showReloadIndicator;
            set
            {
                showReloadIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ShowReloadIndicator)));
            }
        }

        private PackIconKind connectIcon = PackIconKind.CloudQuestion;
        public PackIconKind ConnectIcon
        {
            get => connectIcon;
            set
            {
                connectIcon = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ConnectIcon)));
            }
        }

        public string Server
        {
            get => state.Server.Value;
            set
            {
                state.Server.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Server)));
            }
        }

        public string Port
        {
            get => state.Port.Value;
            set
            {
                state.Port.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Port)));
            }
        }

        public string Database
        {
            get => state.Database.Value;
            set
            {
                state.Database.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Database)));
            }
        }

        public string User
        {
            get => state.User.Value;
            set
            {
                state.User.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(User)));
            }
        }

        public string Password
        {
            get => state.Password.Value;
            set
            {
                state.Password.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Password)));
            }
        }

        public ObservableCollection<AccountApi.IRule> ImportRules
        {
            get => state.ImportRules;
        }

        public ObservableCollection<AccountApi.Wisa.School> Schools
        {
            get => AccountApi.Wisa.SchoolManager.All;
        }
    }
}
