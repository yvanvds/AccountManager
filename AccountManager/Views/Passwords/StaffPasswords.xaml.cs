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

namespace AccountManager.Views.Passwords
{
    
    /// <summary>
    /// Interaction logic for StaffPasswords.xaml
    /// </summary>
    public partial class StaffPasswords : UserControl
    {
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public State.App AppState { get => State.App.Instance; }

        public ObservableCollection<AccountApi.Directory.Account> accounts = new ObservableCollection<AccountApi.Directory.Account>();
        public Prop<AccountApi.Directory.Account> SelectedAccount { get; set; } = new Prop<AccountApi.Directory.Account> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        public Prop<string> SelectedLogin { get; set; } = new Prop<string> { Value = "" };
        public Prop<string> SelectedFirstName { get; set; } = new Prop<string> { Value = "" };
        public Prop<string> SelectedLastName { get; set; } = new Prop<string> { Value = "" };
        public Prop<float> SelectedGender { get; set; } = new Prop<float> { Value = 0.5f };
        public Prop<string> SelectedCopyCode { get; set; } = new Prop<string> { Value = "" };
        public Prop<string> SelectedGroup { get; set; } = new Prop<string> { Value = "" };

        public PropBool IsNewAccount { get; set; } = new PropBool { Value = false };

        enum FilterType
        {
            Name,
            FirstName,
            UID,
            None,
        }

        FilterType filterType { get; set; } = FilterType.Name;
        private string Filter { get; set; } = string.Empty;


        public StaffPasswords()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            CreateCollection();
            AccountList.ItemsSource = accounts;

            SelectedFirstName.SetAction(SetButtonStates);
            SelectedLastName.SetAction(SetButtonStates);
        }

        private void CreateCollection()
        {
            accounts.Clear();
            var selectedFilter = Filter.Length == 0 ? FilterType.None : filterType;

            foreach (var account in AccountApi.Directory.AccountManager.Staff)
            {
                switch (selectedFilter)
                {
                    case FilterType.None: accounts.Add(account); break;
                    case FilterType.FirstName: if (account.FirstName.Contains(Filter)) accounts.Add(account); break;
                    case FilterType.Name: if (account.LastName.Contains(Filter)) accounts.Add(account); break;
                    case FilterType.UID: if (account.UID.Contains(Filter)) accounts.Add(account); break;
                }
            }
            AccountCount.Value = accounts.Count.ToString();
        }

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            SelectedAccount.Value = ((sender as DataGrid).SelectedItem as AccountApi.Directory.Account);
            if(SelectedAccount.Value == null)
            {
                DeselectAccount();
            } else
            {
                SelectAccount();
            }
        }

        private void FilterText_TextChanged(object sender, TextChangedEventArgs e)
        {
            Filter = (sender as TextBox).Text.Trim();
            CreateCollection();
        }

        private void AddAccountButton_Click(object sender, RoutedEventArgs e)
        {
            DeselectAccount();
            IsNewAccount.Value = true;
            SetButtonStates();
        }

        private void SelectAccount()
        {
            SelectedTitle.Value = SelectedAccount.Value.FullName;
            SelectedLogin.Value = SelectedAccount.Value.UID;
            SelectedFirstName.Value = SelectedAccount.Value.FirstName;
            SelectedLastName.Value = SelectedAccount.Value.LastName;
            SelectedCopyCode.Value = SelectedAccount.Value.CopyCode.ToString();
            switch (SelectedAccount.Value.Role)
            {
                case AccountApi.AccountRole.Director: AccountRole.SelectedIndex = 3; break;
                case AccountApi.AccountRole.IT: AccountRole.SelectedIndex = 2; break;
                case AccountApi.AccountRole.Support: AccountRole.SelectedIndex = 1; break;
                case AccountApi.AccountRole.Teacher: AccountRole.SelectedIndex = 0; break;
                default: AccountRole.SelectedIndex = -1; break;

            }

            if (SelectedAccount.Value.Gender == "male")
            {
                SelectedGender.Value = 8f;
            }
            else if (SelectedAccount.Value.Gender == "female")
            {
                SelectedGender.Value = 2f;
            }
            else
            {
                SelectedGender.Value = 5f;
            }
            IsNewAccount.Value = false;

            SetButtonStates();
        }

        private void DeselectAccount()
        {
            SelectedAccount.Value = null;
            SelectedTitle.Value = "";
            SelectedLogin.Value = "";
            SelectedFirstName.Value = "";
            SelectedLastName.Value = "";
            SelectedCopyCode.Value = "";
            AccountRole.SelectedIndex = -1;

            SelectedGender.Value = 5f;
            SetButtonStates();
        }

        private void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var index = (sender as ComboBox).SelectedIndex;
            if (index == 0) filterType = FilterType.Name;
            else if (index == 1) filterType = FilterType.Name;
            else if (index == 2) filterType = FilterType.UID;
            else filterType = FilterType.None;
            CreateCollection();
        }

        private void AccountRole_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            SetButtonStates();
        }

        private void Slider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            SetButtonStates();
        }

        private void SaveButton_Click(object sender, RoutedEventArgs e)
        {
            if(IsNewAccount.Value == true)
            {

            } else
            {
                if(!SelectedAccount.Value.FirstName.Equals(SelectedFirstName.Value))
                {
                    SelectedAccount.Value.FirstName = SelectedFirstName.Value;
                }
                if(!SelectedAccount.Value.LastName.Equals(SelectedLastName.Value))
                {
                    SelectedAccount.Value.LastName = SelectedLastName.Value;
                }

                AccountApi.AccountRole role = AccountApi.AccountRole.Other;
                switch(AccountRole.SelectedIndex)
                {
                    case 0: role = AccountApi.AccountRole.Teacher; break;
                    case 1: role = AccountApi.AccountRole.Support; break;
                    case 2: role = AccountApi.AccountRole.IT; break;
                    case 3: role = AccountApi.AccountRole.Director; break;
                }

                if(SelectedAccount.Value.Role != role)
                {
                    SelectedAccount.Value.Role = role;
                }

                string gender = "not set";
                if (SelectedGender.Value > 7) gender = "male";
                else if (SelectedGender.Value < 2) gender = "female";
                if(!SelectedAccount.Value.Gender.Equals(gender))
                {
                    SelectedAccount.Value.Gender = gender;
                }

                
            }
            SetButtonStates();
        }

        private async void DeleteButton_Click(object sender, RoutedEventArgs e)
        {
            if (SelectedAccount.Value == null) return;
            DeleteButton.IsEnabled = false;

            await AccountApi.Directory.AccountManager.DeleteStaff(SelectedAccount.Value);
            var smartschoolAccount = AccountApi.Smartschool.GroupManager.Root.FindAccount(SelectedAccount.Value.UID);
            if (smartschoolAccount != null)
            {
                await AccountApi.Smartschool.AccountManager.Delete(smartschoolAccount);
            }
            var googleAccount = AccountApi.Google.AccountManager.Find(SelectedAccount.Value.UID);
            if (googleAccount != null)
            {
                await AccountApi.Google.AccountManager.Delete(googleAccount);
            }
            SelectedAccount.Value = null;
            DeselectAccount();

            CreateCollection();
            SetButtonStates();
        }

        private void CreateCopyCodeButton_Click(object sender, RoutedEventArgs e)
        {
            var random = new Random();
            bool valid = false;
            int code = 0;
            while (!valid)
            {
                code = random.Next(1001, 9999);
                valid = true;
                foreach (var account in AccountApi.Directory.AccountManager.Staff)
                {
                    if (code == account.CopyCode) valid = false;
                }
            }
            SelectedCopyCode.Value = code.ToString();

            SetButtonStates();
        }

        private void CreateLoginButton_Click(object sender, RoutedEventArgs e)
        {

            SetButtonStates();
        }

        void SetButtonStates()
        {
            if (SelectedAccount.Value == null && IsNewAccount.Value == false)
            {
                DetailsPanel.Visibility = Visibility.Hidden;
                return;
            }

            DetailsPanel.Visibility = Visibility.Visible;

            if(IsNewAccount.Value == true)
            {
                PCPasswordButton.IsEnabled = false;
                SSPasswordButton.IsEnabled = false;
                AllPasswordButton.IsEnabled = false;

                DeleteButton.IsEnabled = false;

                if(SelectedLogin.Value == "" && SelectedFirstName.Value.Length > 0 && SelectedLastName.Value.Length > 0)
                {
                    CreateLoginButton.IsEnabled = true;
                } else
                {
                    CreateLoginButton.IsEnabled = false;
                }

                if (SelectedCopyCode.Value == "0" || SelectedCopyCode.Value == "")
                {
                    CreateCopyCodeButton.IsEnabled = true;
                }
                else
                {
                    CreateCopyCodeButton.IsEnabled = false;
                }

                bool readyToSave = true;
                if (SelectedFirstName.Value.Length == 0) readyToSave = false;
                if (SelectedLastName.Value.Length == 0) readyToSave = false;
                if (SelectedLogin.Value.Length == 0) readyToSave = false;
                if (SelectedCopyCode.Value.Length == 0) readyToSave = false;
                if (AccountRole.SelectedIndex == -1) readyToSave = false;

                SaveButton.IsEnabled = readyToSave;
            } else
            {
                PCPasswordButton.IsEnabled = true;
                SSPasswordButton.IsEnabled = true;
                AllPasswordButton.IsEnabled = true;

                DeleteButton.IsEnabled = true;

                CreateLoginButton.IsEnabled = false;
                if(SelectedCopyCode.Value == "0" || SelectedCopyCode.Value == "")
                {
                    CreateCopyCodeButton.IsEnabled = true;
                } else
                {
                    CreateCopyCodeButton.IsEnabled = false;
                }

                bool readyToSave = false;
                if (SelectedFirstName.Value != SelectedAccount.Value.FirstName) readyToSave = true;
                if (SelectedLastName.Value != SelectedAccount.Value.LastName) readyToSave = true;
                if (SelectedCopyCode.Value != SelectedAccount.Value.CopyCode.ToString()) readyToSave = true;

                SaveButton.IsEnabled = readyToSave;
            }
        }
    }
}
