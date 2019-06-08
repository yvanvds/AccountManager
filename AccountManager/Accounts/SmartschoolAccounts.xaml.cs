using AbstractAccountApi;
using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Accounts
{
    /// <summary>
    /// Interaction logic for SmartschoolAccounts.xaml
    /// </summary>
    public partial class SmartschoolAccounts : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Prop<IAccount> SelectedAccount { get; set; } = new Prop<IAccount> { Value = null };
        public Data Data { get => Data.Instance; }

        private Select Select = Select.Students;
        private Group currentRoot;

        public SmartschoolAccounts()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            BuildAccountTree();
        }

        private void BuildAccountTree()
        {
            AccountTree.Items.Clear();
            if (Select == Select.Staff)
            {
                IGroup root = AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
                currentRoot = new Group(root);
            }
            else
            {
                IGroup root = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
                currentRoot = new Group(root);
            }
            foreach (var child in currentRoot.Children)
            {
                AccountTree.Items.Add(child);
            }

            AccountCount.Value = currentRoot.CountAccount.ToString();
        }

        private void StudentButton_Click(object sender, RoutedEventArgs e)
        {
            Select = Select.Students;
            BuildAccountTree();
        }

        private void StaffButton_Click(object sender, RoutedEventArgs e)
        {
            Select = Select.Staff;
            BuildAccountTree();
        }

        private async void ReloadAccountButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetSmartschoolCredentials();
            await Data.Instance.ReloadSmartschool();
            BuildAccountTree();

            ShowGroupsReloadButtonIndicator.Value = false;
        }

        private void AccountTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            if(AccountTree.SelectedItem != null)
            {
                if (AccountTree.SelectedItem is Group) {
                    AccountCount.Value = (AccountTree.SelectedItem as Group).CountAccount.ToString();
                    SelectedAccount.Value = null;
                } else if (AccountTree.SelectedItem is Account)
                {
                    AccountCount.Value = currentRoot.CountAccount.ToString();
                    SelectedAccount.Value = (AccountTree.SelectedItem as Account).Base;
                }
            } else
            {
                AccountCount.Value = currentRoot.CountAccount.ToString();
            }
        }
    }

    enum Select
    {
        All,
        Staff,
        Students,
    }

    class Group
    {
        public ObservableCollection<object> Children { get; set; }
        public IGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";
        public int CountAccount { get; set; } = 0;

        public Group(IGroup Base)
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
                    Children.Add(new Group(group));
                    CountAccount += (Children.Last() as Group).CountAccount;
                }

            }

            if (Base.Accounts != null)
            {
                foreach(var account in Base.Accounts)
                {
                    Children.Add(new Account(account));
                }
                CountAccount += Base.Accounts.Count;
            }
        }
    }

    class Account
    {
        public IAccount Base;
        public string Header { get; set; } = "Invalid Account";
        public string Icon { get; set; } = "GenderTransgender";

        public Account(IAccount Base)
        {
            this.Base = Base;
            if (Base == null) return;

            Header = Base.SurName + " " + Base.GivenName;
            if(Base.Gender == GenderType.Female)
            {
                Icon = "GenderFemale";
            } else if (Base.Gender == GenderType.Male)
            {
                Icon = "GenderMale";
            } else
            {
                Icon = "GenderTransgender";
            }
        }
    }
}
