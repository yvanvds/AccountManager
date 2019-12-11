using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Accounts
{
    class SmartschoolAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.Smartschool.SmartschoolState state;

        public IAsyncCommand ReloadCommand { get; private set; }
        public ICommand SetTargetCommand { get; private set; }

        public SmartschoolAccounts()
        {
            state = State.App.Instance.Smartschool;
            state.AddObserver(this);

            ReloadCommand = new RelayAsyncCommand(ReloadAccounts);
            SetTargetCommand = new RelayCommand<string>(SetTarget);

            updateSelection();
        }
        ~SmartschoolAccounts()
        {
            state.RemoveObserver(this);
        }


        #region Commands

        private void SetTarget(string obj)
        {
            Target = obj;
        }

        private async Task ReloadAccounts()
        {
            Indicator = true;
            await state.LoadContent().ConfigureAwait(false);
            updateSelection();
            Indicator = false;
        }
        #endregion

        private List<object> tree = new List<object>();
        public List<object> Tree => tree;

        private void updateSelection()
        {
            tree.Clear();
            IGroup root = AccountApi.Smartschool.GroupManager.Root.Find(Target);
            var treeRoot = new TreeGroup(root);
            foreach(var child in treeRoot.Children)
            {
                tree.Add(child);
            }
            NumAccounts = treeRoot.CountAccount;

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Tree)));
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        private int numAccounts = 0;
        public int NumAccounts
        {
            get => numAccounts;
            set
            {
                numAccounts = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(NumAccounts)));
            }
        }

        private string target = "Leerlingen";
        public string Target
        {
            get => target;
            set
            {
                target = value;
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Target)));
            }
        }

        TreeAccount selectedAccount = null;
        public TreeAccount SelectedAccount
        {
            get => selectedAccount;
            set
            {
                selectedAccount = (value is TreeAccount) ? value : null;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccount)));
            }
        }

        bool indicator = false;
        public bool Indicator
        {
            get => indicator;
            set
            {
                indicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Indicator)));
            }
        }

        public void OnStateChanges()
        {
            updateSelection();
        }
    }

    public class TreeGroup
    {
        public ObservableCollection<object> Children { get; private set; }
        public IGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";
        public int CountAccount { get; set; } = 0;

        public TreeGroup(IGroup Base)
        {
            this.Base = Base;
            Children = new ObservableCollection<object>();

            if (Base == null) return;

            Header = Base.Name;
            if (Base.Official)
            {
                Icon = "Class";
            }
            else
            {
                Icon = "UserGroup";
            }

            if (Base.Children != null)
            {
                foreach (var group in Base.Children)
                {
                    Children.Add(new TreeGroup(group));
                    CountAccount += (Children.Last() as TreeGroup).CountAccount;
                }

            }

            if (Base.Accounts != null)
            {
                foreach (var account in Base.Accounts)
                {
                    Children.Add(new TreeAccount(account));
                }
                CountAccount += Base.Accounts.Count;
            }
        }
    }

    public class TreeAccount
    {
        public IAccount Base { get; private set; }
        public string Header { get; set; } = "Invalid Account";
        public string Icon { get; set; } = "GenderTransgender";

        public TreeAccount(IAccount Base)
        {
            this.Base = Base;
            if (Base == null) return;

            Header = Base.SurName + " " + Base.GivenName;
            if (Base.Gender == GenderType.Female)
            {
                Icon = "GenderFemale";
            }
            else if (Base.Gender == GenderType.Male)
            {
                Icon = "GenderMale";
            }
            else
            {
                Icon = "GenderTransgender";
            }
        }
    }
}
