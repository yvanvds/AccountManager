using AbstractAccountApi;
using AccountApi;
using AccountManager.Exporters.Passwords;
using AccountManager.Utils;
using Microsoft.Win32;
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
            IGroup leerlingen = State.App.Instance.Smartschool.Groups.Root.Find("Leerlingen");
            foreach (var group in leerlingen.Children)
            {
                GroupTree.Items.Add(new DisplayItems.SSGroup(group));
            }
        }

        private void GroupTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            var group = ((sender as TreeView).SelectedItem as DisplayItems.SSGroup).Base;

            currentGroup = new List<DisplayItems.StudentPasswordItem>();

            foreach(var account in group.Accounts)
            {
                var item = new DisplayItems.StudentPasswordItem(account);

                item.SmartschoolPassword.Value = CheckSmartschool.IsChecked ?? false;
                item.AzurePassword.Value = CheckAzure.IsChecked ?? false;

                item.SmartschoolCo1Password.Value = CheckCo1.IsChecked ?? false;
                item.SmartschoolCo2Password.Value = CheckCo2.IsChecked ?? false;
                item.SmartschoolCo3Password.Value = CheckCo3.IsChecked ?? false;
                item.SmartschoolCo4Password.Value = CheckCo4.IsChecked ?? false;
                item.SmartschoolCo5Password.Value = CheckCo5.IsChecked ?? false;
                item.SmartschoolCo6Password.Value = CheckCo6.IsChecked ?? false;

                currentGroup.Add(item);
            }
            currentGroup.Sort((a, b) => a.Account.SurName.CompareTo(b.Account.SurName));

            AccountList.ItemsSource = currentGroup;
        }

        private void CheckAzure_Checked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.AzurePassword.Value = true;
            }
        }

        private void CheckAzure_Unchecked(object sender, RoutedEventArgs e)
        {
            foreach (var item in currentGroup)
            {
                item.AzurePassword.Value = false;
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
                var password = Password.Create();


                if (item.AzurePassword.Value == true)
                {
                    item.NewAzurePassword = password;
                    var user = AccountApi.Azure.UserManager.Instance.FindAccountByPrincipalName(item.Account.Mail);
                    if (user != null)
                    {
                        await AccountApi.Azure.UserManager.Instance.SetPassword(user, password).ConfigureAwait(false);
                    } else
                    {
                        MainWindow.Instance.Log.AddMessage(Origin.Azure, "No account for " + item.Account.GivenName + " " + item.Account.SurName);
                    }
                }

                var ssAccount = AccountApi.Smartschool.GroupManager.Root.FindAccount(item.UserName);

                if(ssAccount != null)
                {
                    if (item.SmartschoolPassword.Value == true)
                    {
                        item.NewSmartschoolPassword = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolPassword, AccountApi.AccountType.Student).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo1Password.Value == true)
                    {
                        item.NewSmartschoolCo1Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo1Password, AccountApi.AccountType.CoAccount1).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo2Password.Value == true)
                    {
                        item.NewSmartschoolCo2Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo2Password, AccountApi.AccountType.CoAccount2).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo3Password.Value == true)
                    {
                        item.NewSmartschoolCo3Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo3Password, AccountApi.AccountType.CoAccount3).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo4Password.Value == true)
                    {
                        item.NewSmartschoolCo4Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo4Password, AccountApi.AccountType.CoAccount4).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo5Password.Value == true)
                    {
                        item.NewSmartschoolCo5Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo5Password, AccountApi.AccountType.CoAccount5).ConfigureAwait(false);
                    }

                    if (item.SmartschoolCo6Password.Value == true)
                    {
                        item.NewSmartschoolCo6Password = AccountApi.Password.Create();
                        await AccountApi.Smartschool.AccountManager.SetPassword(ssAccount, item.NewSmartschoolCo6Password, AccountApi.AccountType.CoAccount6).ConfigureAwait(false);
                    }
                } else
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "The Account for " + item.Name + " is not found.");
                }


                if(item.SmartschoolPassword.Value || item.AzurePassword.Value)
                {
                    Exporters.PasswordManager.Instance.Accounts.List.Add(new AccountPassword(item.UserName, item.Name, item.Account.Mail, item.Account.Group, item.NewSmartschoolPassword, item.NewAzurePassword));  
                }

                if(    item.SmartschoolCo1Password.Value || item.SmartschoolCo2Password.Value 
                    || item.SmartschoolCo3Password.Value || item.SmartschoolCo4Password.Value 
                    || item.SmartschoolCo5Password.Value || item.SmartschoolCo6Password.Value)
                {
                    var pw = new CoAccountPassword(item.UserName, item.Name, item.Account.Group);
                    pw.Co1 = item.NewSmartschoolCo1Password;
                    pw.Co2 = item.NewSmartschoolCo2Password;
                    pw.Co3 = item.NewSmartschoolCo3Password;
                    pw.Co4 = item.NewSmartschoolCo4Password;
                    pw.Co5 = item.NewSmartschoolCo5Password;
                    pw.Co6 = item.NewSmartschoolCo6Password;
                    Exporters.PasswordManager.Instance.CoAccounts.List.Add(pw);
                }

                item.SmartschoolPassword.Value = false;
                item.AzurePassword.Value = false;

                item.SmartschoolCo1Password.Value = false;
                item.SmartschoolCo2Password.Value = false;
                item.SmartschoolCo3Password.Value = false;
                item.SmartschoolCo4Password.Value = false;
                item.SmartschoolCo5Password.Value = false;
                item.SmartschoolCo6Password.Value = false;
            }
            UpdateButtons();
        }

        private void SingleSmartschoolCheck_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.SmartschoolPassword.Value = checkbox.IsChecked ?? false;
        }

        private void SingleAzureCheck_Checked(object sender, RoutedEventArgs e)
        {
            var checkbox = sender as CheckBox;
            var item = checkbox.DataContext as DisplayItems.StudentPasswordItem;
            item.AzurePassword.Value = checkbox.IsChecked ?? false;
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
                await Exporters.PasswordManager.Instance.CoAccounts.Export(dialog.FileName).ConfigureAwait(false); 
            }
            UpdateButtons();
        }

        private async void PrintButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SaveFileDialog();
            dialog.Filter = "pdf file (.pdf)|*.pdf";

            if (dialog.ShowDialog() == true)
            {
                await Exporters.PasswordManager.Instance.Accounts.Export(dialog.FileName).ConfigureAwait(false);
            }
            UpdateButtons();
        }
    }

    
}
