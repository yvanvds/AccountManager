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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Settings
{
    /// <summary>
    /// Interaction logic for ADSettings.xaml
    /// </summary>
    public partial class ADSettings : UserControl
    {
        public Prop<bool> ShowConnectButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<bool> ShowSchoolReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };

        PackIcon ConnectButtonIcon;

        public Data Data { get => Data.Instance; }

        public ADSettings()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
        }

        private void TestConnectButton_Click(object sender, RoutedEventArgs e)
        {
            ShowConnectButtonIndicator.Value = true;
            testADConnection();
            ShowConnectButtonIndicator.Value = false;
        }

        private void testADConnection()
        {
            bool result = Data.Instance.SetADCredentials();
            if (!result) ConnectButtonIcon.Kind = PackIconKind.CloudOffOutline;
            else ConnectButtonIcon.Kind = PackIconKind.CloudTick;
        }

        private void ConnectButtonIconControl_Loaded(object sender, RoutedEventArgs e)
        {
            ConnectButtonIcon = sender as PackIcon;
        }
    }
}
