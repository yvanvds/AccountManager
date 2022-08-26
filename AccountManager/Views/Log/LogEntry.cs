using AbstractAccountApi;
using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Media;

namespace AccountManager.Views.Log
{
    class LogEntry
    {
        public Origin Origin { get; set; }
        public bool Error { get; set; }
        public string Content { get; set; }

        public string Source
        {
            get
            {
                switch (Origin)
                {
                    case Origin.Directory: return "AD";
                    case Origin.Wisa: return "WI";
                    case Origin.Smartschool: return "SS";
                    case Origin.Google: return "GO";
                    case Origin.Azure: return "365";
                    default: return "-";
                }
            }
        }

        public Brush Color
        {
            get
            {
                if (Error) return new SolidColorBrush(Colors.DarkRed);
                return new SolidColorBrush(Colors.DarkGreen);
            }
        }
    }
}