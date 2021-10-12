﻿using AccountApi;
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
    class ADSettings : INotifyPropertyChanged
    {
        State.AD.ADState state;
        public IAsyncCommand TestConnectionCommand { get; set; }
        public IAsyncCommand AddRuleCommand { get; private set; }
        public IAsyncCommand<IRule> EditRuleCommand { get; set; }
        public ICommand DeleteRuleCommand { get; set; }

        public ADSettings()
        {
            state = State.App.Instance.AD;
            this.TestConnectionCommand = new RelayAsyncCommand(TestConnection);
            this.AddRuleCommand = new RelayAsyncCommand(AddRule);
            this.EditRuleCommand = new RelayAsyncCommand<IRule>(EditRule);
            this.DeleteRuleCommand = new RelayCommand<IRule>(DeleteRule);
        }



        #region commands
        private async Task TestConnection()
        {
            ShowConnectIndicator = true;

            await Task.Run(async () =>
            {
                bool result = await state.Connect().ConfigureAwait(false);
                if (!result) ConnectIcon = PackIconKind.CloudOffOutline;
                else ConnectIcon = PackIconKind.CloudTick;
            }).ConfigureAwait(false);

            ShowConnectIndicator = false;
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
                case Rule.AD_DontImportUser: editor = new AD_DontImportUser(parameter); break;
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
            var dialog = new ImportRuleSelectDialog(AccountApi.RuleType.AD_Import);
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

        #endregion

        #region properties
        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        public string Domain
        {
            get => state.Domain.Value;
            set
            {
                state.Domain.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Domain)));
            }
        }

        public string AccountRoot
        {
            get => state.AccountRoot.Value;
            set
            {
                state.AccountRoot.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(AccountRoot)));
            }
        }

        public string ClassesRoot
        {
            get => state.ClassesRoot.Value;
            set
            {
                state.ClassesRoot.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ClassesRoot)));
            }
        }

        public string StudentRoot
        {
            get => state.StudentRoot.Value;
            set
            {
                state.StudentRoot.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(StudentRoot)));
            }
        }

        public string StaffRoot
        {
            get => state.StaffRoot.Value;
            set
            {
                state.StaffRoot.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(StaffRoot)));
            }
        }

        public string AzureDomain
        {
            get => state.AzureDomain.Value;
            set
            {
                state.AzureDomain.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureDomain)));
            }
        }

        public string IPAddress
        {
            get => state.IPAddress.Value;
            set
            {
                state.IPAddress.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IPAddress)));
            }
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

        public bool CheckHomeDirs
        {
            get => state.CheckHomeDirs.Value;
            set
            {
                state.CheckHomeDirs.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CheckHomeDirs)));
            }
        }

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

        public ObservableCollection<AccountApi.IRule> ImportRules
        {
            get => state.ImportRules;
        }

        #endregion
    }
}
