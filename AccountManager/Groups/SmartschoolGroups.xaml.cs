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
    /// Interaction logic for SmartschoolGroups.xaml
    /// </summary>
    public partial class SmartschoolGroups : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> GroupCount { get; set; } = new Prop<string> { Value = "0" };
        public Prop<IGroup> SelectedGroup { get; set; } = new Prop<IGroup> { Value = null };
        public Data Data { get => Data.Instance; }

        private Select Select = Select.All;

        public SmartschoolGroups()
        {
            InitializeComponent();
            GroupCount.Value = AccountApi.Smartschool.GroupManager.Count(false).ToString();
            MainGrid.DataContext = this;
            BuildGroupTree();
        }

        private async void ReloadClassButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetSmartschoolCredentials();
            await Data.Instance.ReloadSmartschool();
            await LinkedGroups.ReLink();
            GroupCount.Value = AccountApi.Smartschool.GroupManager.Count(false).ToString();
            BuildGroupTree();

            ShowGroupsReloadButtonIndicator.Value = false;
        }

        private void BuildGroupTree()
        {
            GroupTree.Items.Clear();
            if(Select == Select.All)
            {
                GroupTree.Items.Add(new SSGroup(AccountApi.Smartschool.GroupManager.Root));
                GroupCount.Value = AccountApi.Smartschool.GroupManager.Root.Count.ToString();
            } else if (Select == Select.Staff)
            {
                IGroup root = AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
                GroupTree.Items.Add(new SSGroup(root));
                GroupCount.Value = root.Count.ToString();
            } else
            {
                IGroup root = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
                GroupTree.Items.Add(new SSGroup(root));
                GroupCount.Value = root.Count.ToString();
            }
            
        }

        private void GroupTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            if (GroupTree.SelectedItem != null)
            {
                SelectedGroup.Value = (GroupTree.SelectedItem as SSGroup).Base;
            }
            else SelectedGroup.Value = null;
        }

        private void AllGroupsButton_Click(object sender, RoutedEventArgs e)
        {
            Select = Select.All;
            BuildGroupTree();
        }

        private void ClassButton_Click(object sender, RoutedEventArgs e)
        {
            Select = Select.Students;
            BuildGroupTree();
        }

        private void StaffButton_Click(object sender, RoutedEventArgs e)
        {
            Select = Select.Staff;
            BuildGroupTree();
        }
    }

    enum Select
    {
        All,
        Staff,
        Students,
    }

    class SSGroup
    {
        public ObservableCollection<SSGroup> Children { get; set; }
        public IGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";

        public SSGroup(IGroup Base)
        {
            this.Base = Base;
            Children = new ObservableCollection<SSGroup>();

            if (Base == null) return;

            Header = Base.Name;
            if(Base.Official)
            {
                Icon = "Class";
            } else
            {
                Icon = "UserGroup";
            }

            if (Base.Children == null) return;
            foreach(var group in Base.Children)
            {
                Children.Add(new SSGroup(group));
            }
        }
    }
}
