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
    class SmartschoolSettings : INotifyPropertyChanged
    {
        State.Smartschool.SmartschoolState state;
        public IAsyncCommand TestConnectionCommand { get; private set; }
        public IAsyncCommand AddRuleCommand { get; private set; }
        public IAsyncCommand<IRule> EditRuleCommand { get; set; }
        public ICommand DeleteRuleCommand { get; set; }

        public SmartschoolSettings()
        {
            state = State.App.Instance.Smartschool;
            this.TestConnectionCommand = new RelayAsyncCommand(TestConnection);
            this.AddRuleCommand = new RelayAsyncCommand(AddRule);
            this.EditRuleCommand = new RelayAsyncCommand<IRule>(EditRule);
            this.DeleteRuleCommand = new RelayCommand<IRule>(DeleteRule);
        }

        private void DeleteRule(object parameter)
        {
            var rule = parameter as IRule;
            state.ImportRules.Remove(rule);
        }

        private async Task EditRule(IRule parameter)
        {
            var rule = parameter as IRule;
            
            IRuleEditor editor = null;
            switch (rule.Rule)
            {
                case Rule.SS_DiscardGroup: editor = new Views.Dialogs.SS_DiscardGroupEditor(rule); break;
                case Rule.SS_NoSubGroups: editor = new Views.Dialogs.SS_DiscardSubGroupEditor(rule); break;
            }

            if (editor != null)
            {
                await DialogHost.Show(
                    editor,
                    "RootDialog"
                );
            }
        }

        private async Task AddRule()
        {
            var dialog = new Views.Dialogs.ImportRuleSelectDialog(AccountApi.RuleType.SS_Import);
            await DialogHost.Show(
                dialog,
                "RootDialog",
                (sender, eventArgs) =>
                {
                    var result = eventArgs.Parameter as string;
                    if (result == "true")
                    {
                        var rule = state.AddImportRule(dialog.SelectedRule);
                        eventArgs.Handled = true;
                    }
                }
            );
        }

        private async Task TestConnection()
        {
            ShowConnectIndicator = true;
            state.Connect();
            var account = new AccountApi.Smartschool.Account
            {
                UID = state.TestUser.Value
            };

            bool result = await AccountApi.Smartschool.AccountManager.Load(account);
            if (result)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Connection Succeeded");
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Connection Failed");
            }

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

        public string Uri
        {
            get => state.Uri.Value;
            set
            {
                state.Uri.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Uri)));
            }
        }

        public string Passphrase
        {
            get => state.Passphrase.Value;
            set
            {
                state.Passphrase.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Passphrase)));
            }
        }

        public string TestUser
        {
            get => state.TestUser.Value;
            set
            {
                state.TestUser.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(TestUser)));
            }
        }

        public string StudentGroup
        {
            get => state.StudentGroup.Value;
            set
            {
                state.StudentGroup.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(StudentGroup)));
            }
        }

        public string StaffGroup
        {
            get => state.StaffGroup.Value;
            set
            {
                state.StaffGroup.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(StaffGroup)));
            }
        }

        public ObservableCollection<AccountApi.IRule> ImportRules
        {
            get => state.ImportRules;
        }

        public bool UseGrades
        {
            get => state.UseGrades.Value;
            set
            {
                state.UseGrades.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(UseGrades)));
            }
        }

        public bool UseYears
        {
            get => state.UseYears.Value;
            set
            {
                state.UseYears.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(UseYears)));
            }
        }

        public string Grade1
        {
            get => state.Grade1;
            set
            {
                state.Grade1 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Grade1)));
            }
        }

        public string Grade2
        {
            get => state.Grade2;
            set
            {
                state.Grade2 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Grade2)));
            }
        }

        public string Grade3
        {
            get => state.Grade3;
            set
            {
                state.Grade3 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Grade3)));
            }
        }

        public string Year1
        {
            get => state.Year1;
            set
            {
                state.Year1 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year1)));
            }
        }

        public string Year2
        {
            get => state.Year2;
            set
            {
                state.Year2 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year2)));
            }
        }

        public string Year3
        {
            get => state.Year3;
            set
            {
                state.Year3 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year3)));
            }
        }

        public string Year4
        {
            get => state.Year4;
            set
            {
                state.Year4 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year4)));
            }
        }

        public string Year5
        {
            get => state.Year5;
            set
            {
                state.Year5 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year5)));
            }
        }

        public string Year6
        {
            get => state.Year6;
            set
            {
                state.Year6 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year6)));
            }
        }

        public string Year7
        {
            get => state.Year7;
            set
            {
                state.Year7 = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Year7)));
            }
        }
    }
}
