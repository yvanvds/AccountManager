using MaterialDesignThemes.Wpf;
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

namespace AccountManager.Views.Groups
{
    /// <summary>
    /// Interaction logic for GroupsPage.xaml
    /// </summary>
    public partial class GroupsPage : UserControl
    {
        public enum Tab {
            Overview,
            Wisa,
            Smartschool,
        }

        public GroupsPage(Tab activeTab = Tab.Overview)
        {
            InitializeComponent();
            switch(activeTab)
            {
                case Tab.Overview: TabControl.SelectedIndex = 0; break;
                case Tab.Wisa: TabControl.SelectedIndex = 1; break;
                case Tab.Smartschool: TabControl.SelectedIndex = 2; break;
            }

            if(!State.App.Instance.Settings.DebugMode.Value)
            {
                TabControl.SelectedIndex = 0;
                TabControl.Items.Remove(WisaTab);
                TabControl.Items.Remove(SmartschoolTab);
            }
        }
    }
}
