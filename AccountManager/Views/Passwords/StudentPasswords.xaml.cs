using AbstractAccountApi;
using AccountManager.Exporters.Passwords;
using Microsoft.Win32;
using System;
using System.Collections.Generic;
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
    /// Interaction logic for StudentPasswords.xaml
    /// </summary>
    public partial class StudentPasswords : UserControl
    {
        List<DisplayItems.StudentPasswordItem> currentGroup;
        public Prop<bool> EnablePrintButton { set; get; } = new Prop<bool>() { Value = false };
        public Prop<bool> EnableSaveButton { set; get; } = new Prop<bool>() { Value = false };
        public Prop<int> PrintButtonBadge { set; get; } = new Prop<int>() { Value = 0 };
        public Prop<int> SaveButtonBadge { set; get; } = new Prop<int>() { Value = 0 };

        public StudentPasswords()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            BuildGroupTree();
            UpdateButtons();
        }

        private void UpdateButtons()
        {
            EnablePrintButton.Value = Exporters.PasswordManager.Instance.Accounts.List.Count > 0;
            EnableSaveButton.Value = Exporters.PasswordManager.Instance.CoAccounts.List.Count > 0;
            PrintButtonBadge.Value = Exporters.PasswordManager.Instance.Accounts.List.Count;
            SaveButtonBadge.Value = Exporters.PasswordManager.Instance.CoAccounts.List.Count;
        }

        private void BuildGroupTree()
        {
            GroupTree.Items.Clear();
            foreach (var group in State.App.Instance.AD.Groups.List)
            {
                GroupTree.Items.Add(new DisplayItems.ADGroup(group));
            }
        }

        private void GroupTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            var group = ((sender as TreeView).SelectedItem as DisplayItems.ADGroup).Base;

            currentGroup = new List<DisplayItems.StudentPasswordItem>();

            foreach(var account in AccountApi.Directory.AccountManager.Students)
            {
                if(account.ClassGroup == group.Name)
                {
                    var item = new DisplayItems.StudentPasswordItem(account);

                    item.DirectoryPassword.Value = CheckDirectory.IsChecked ?? false;
                    item.SmartschoolPassword.Value = CheckSmartschool.IsChecked ?? false;

                    item.SmartschoolCo1Password.Value = CheckCo1.IsChecked ?? false;
                    item.SmartschoolCo2Password.Value = CheckCo2.IsChecked ?? false;
                    item.SmartschoolCo3Password.Value = CheckCo3.IsChecked ?? false;
                    item.SmartschoolCo4Password.Value = CheckCo4.IsChecked ?? false;
                    item.SmartschoolCo5Password.Value = CheckCo5.IsChecked ?? false;
                    item.SmartschoolCo6Password.Value = CheckCo6.IsChecked ?? false;

                    currentGroup.Add(item);
                }
            }
            currentGroup.Sort((a, b) => a.Account.LastName.CompareTo(b.Account.LastName));

            AccountList.ItemsSource = currentGroup;
        }

        private void CheckDirectory_Checked(object sender, RoutedEventArgs e)
        {
            foreach(var item in currentGroup)
            {
                item.DirectoryPassword.Value = true;
            }
        }

        private void CheckDirectory_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.DirectoryPassword.Value = false;
            }
        }

        private void CheckSmartschool_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolPassword.Value = true;
            }
        }

        private void CheckSmartschool_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolPassword.Value = false;
            }
        }

        private void CheckCo1_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo1Password.Value = true;
            }
        }

        private void CheckCo1_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo1Password.Value = false;
            }
        }

        private void CheckCo2_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo2Password.Value = true;
            }
        }

        private void CheckCo2_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo2Password.Value = false;
            }
        }

        private void CheckCo3_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo3Password.Value = true;
            }
        }

        private void CheckCo3_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo3Password.Value = false;
            }
        }

        private void CheckCo4_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo4Password.Value = true;
            }
        }

        private void CheckCo4_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo4Password.Value = false;
            }
        }

        private void CheckCo5_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo5Password.Value = true;
            }
        }

        private void CheckCo5_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo5Password.Value = false;
            }
        }

        private void CheckCo6_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo6Password.Value = true;
            }
        }

        private void CheckCo6_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.SmartschoolCo6Password.Value = false;
            }
        }

        private async void GenerateButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                if(item.DirectoryPassword.Value == true)
                {
                    item.NewDirectoryPassword = AccountApi.Password.Create();
                    item.Account.SetPassword(item.NewDirectoryPassword);
                }

                var ssAccount = AccountApi.Smartschool.GroupManager.Root.FindAccount(item.UserName);

                if(ssAccount != null)
                {
                    if (item.SmartschoolPassword.Value == true)
                    {
                        item.NewSmartschoolPassword = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolPassword, AccountApi.AccountType.Student);
                    }

                    if (item.SmartschoolCo1Password.Value == true)
                    {
                        item.NewSmartschoolCo1Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo1Password, AccountApi.AccountType.CoAccount1);
                    }

                    if (item.SmartschoolCo2Password.Value == true)
                    {
                        item.NewSmartschoolCo2Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo2Password, AccountApi.AccountType.CoAccount2);
                    }

                    if (item.SmartschoolCo3Password.Value == true)
                    {
                        item.NewSmartschoolCo3Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo3Password, AccountApi.AccountType.CoAccount3);
                    }

                    if (item.SmartschoolCo4Password.Value == true)
                    {
                        item.NewSmartschoolCo4Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo4Password, AccountApi.AccountType.CoAccount4);
                    }

                    if (item.SmartschoolCo5Password.Value == true)
                    {
                        item.NewSmartschoolCo5Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo5Password, AccountApi.AccountType.CoAccount5);
                    }

                    if (item.SmartschoolCo6Password.Value == true)
                    {
                        item.NewSmartschoolCo6Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo6Password, AccountApi.AccountType.CoAccount6);
                    }
                } else
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "The Account for " + item.Name + " is not found.");
                }


                if(item.DirectoryPassword.Value || item.SmartschoolPassword.Value)
                {
                    Exporters.PasswordManager.Instance.Accounts.List.Add(new AccountPassword(item.UserName, item.Name, item.Account.ClassGroup, item.NewDirectoryPassword, item.NewSmartschoolPassword));  
                }

                if(    item.SmartschoolCo1Password.Value || item.SmartschoolCo2Password.Value 
                    || item.SmartschoolCo3Password.Value || item.SmartschoolCo4Password.Value 
                    || item.SmartschoolCo5Password.Value || item.SmartschoolCo6Password.Value)
                {
                    var pw = new CoAccountPassword(item.UserName, item.Name, item.Account.ClassGroup);
                    pw.Co1 = item.NewSmartschoolCo1Password;
                    pw.Co2 = item.NewSmartschoolCo2Password;
                    pw.Co3 = item.NewSmartschoolCo3Password;
                    pw.Co4 = item.NewSmartschoolCo4Password;
                    pw.Co5 = item.NewSmartschoolCo5Password;
                    pw.Co6 = item.NewSmartschoolCo6Password;
                    Exporters.PasswordManager.Instance.CoAccounts.List.Add(pw);
                }

                item.DirectoryPassword.Value = false;
                item.SmartschoolPassword.Value = false;

                item.SmartschoolCo1Password.Value = false;
                item.SmartschoolCo2Password.Value = false;
                item.SmartschoolCo3Password.Value = false;
                item.SmartschoolCo4Password.Value = false;
                item.SmartschoolCo5Password.Value = false;
                item.SmartschoolCo6Password.Value = false;
            }
            UpdateButtons();
        }

        private void SingleDirectoryCheck_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.DirectoryPassword.Value = checkbox.IsChecked ?? false;
        }

        private void SingleSmartschoolCheck_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolPassword.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo1Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo1Password.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo2Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo2Password.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo3Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo3Password.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo4Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo4Password.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo5Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo5Password.Value = checkbox.IsChecked ?? false;
        }

        private void SingleCo6Check_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolCo6Password.Value = checkbox.IsChecked ?? false;
        }

        private async void SaveToCsvButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SaveFileDialog();
            dialog.Filter = "csv file (.csv)|*.csv";

            if (dialog.ShowDialog() == true)
            {
                await Exporters.PasswordManager.Instance.CoAccounts.Export(dialog.FileName); 
            }
            UpdateButtons();
        }

        private async void PrintButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SaveFileDialog();
            dialog.Filter = "pdf file (.pdf)|*.pdf";

            if (dialog.ShowDialog() == true)
            {
                await Exporters.PasswordManager.Instance.Accounts.Export(dialog.FileName);
            }
            UpdateButtons();
        }
    }
}
