using AccountApi;
using AccountManager.Utils;
using MaterialDesignThemes.Wpf;
using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Settings
{
    /// <summary>
    /// Interaction logic for WisaSettings.xaml
    /// </summary>
    public partial class WisaSettings : UserControl
    {

        ViewModels.Settings.WisaSettings settings;

        public WisaSettings()
        {
            InitializeComponent();
            settings = new ViewModels.Settings.WisaSettings();
            this.DataContext = settings;

            settings.TestConnectionCommand.ExecuteAsync().FireAndForgetSafeAsync();
        }
    }
}
