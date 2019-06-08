using AbstractAccountApi;
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

namespace AccountManager.Passwords
{
    /// <summary>
    /// Interaction logic for StudentPasswords.xaml
    /// </summary>
    public partial class StudentPasswords : UserControl
    {
        List<DisplayItems.StudentPasswordItem> currentGroup;

        public StudentPasswords()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            BuildGroupTree();
        }

        private void BuildGroupTree()
        {
            GroupTree.Items.Clear();
            foreach (var group in Data.Instance.ADGroups)
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
                    currentGroup.Add(new DisplayItems.StudentPasswordItem(account));
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

        }

        private void CheckSmartschool_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo1_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo1_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo2_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo2_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo3_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo3_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo4_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo4_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo5_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo5_Unchecked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo6_Checked(object sender, RoutedEventArgs e)
        {

        }

        private void CheckCo6_Unchecked(object sender, RoutedEventArgs e)
        {

        }
    }
}
