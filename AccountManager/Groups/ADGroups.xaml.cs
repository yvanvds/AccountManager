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

namespace AccountManager.Groups
{
    /// <summary>
    /// Interaction logic for ADGroups.xaml
    /// </summary>
    public partial class ADGroups : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> GroupCount { get; set; } = new Prop<string> { Value = "0" };
        public Prop<IGroup> SelectedGroup { get; set; } = new Prop<IGroup> { Value = null };

        public Data Data { get => Data.Instance; }

        public ADGroups()
        {
            InitializeComponent();
            GroupCount.Value = AccountApi.Directory.ClassGroupManager.Count(true).ToString();
            MainGrid.DataContext = this;
            BuildGroupTree();
        }

        private async void ReloadClassButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetADCredentials();
            await Data.Instance.ReloadADClassGroups();
            await LinkedGroups.ReLink();
            GroupCount.Value = AccountApi.Directory.ClassGroupManager.Count(true).ToString();
            BuildGroupTree();
            ShowGroupsReloadButtonIndicator.Value = false;
        }

        private void BuildGroupTree()
        {
            GroupTree.Items.Clear();
            foreach(var group in Data.Instance.ADGroups)
            {
                GroupTree.Items.Add(new DisplayItems.ADGroup(group));
            }
            GroupCount.Value = AccountApi.Directory.ClassGroupManager.Count(true).ToString();
        }

        private void GroupTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {

        }
    }

}
