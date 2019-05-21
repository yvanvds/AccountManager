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
using MahApps.Metro.Controls;

namespace AccountManager
{
    /// <summary>
    /// Interaction logic for MainWindow.xaml
    /// </summary>
    public partial class MainWindow : MetroWindow
    {
        static public MainWindow Instance;
        

        public MainWindow()
        {
            InitializeComponent();
            Instance = this;
            Data.Instance.LoadFileContentOnStartup();
        }

        public void Navigate(UserControl page)
        {
            Content.Children.Clear();
            Content.Children.Add(page);
        }
    }
}
